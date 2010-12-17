%% -------------------------------------------------------------------
%%
%% mi: Merge-Index Data Store
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc. All Rights Reserved.
%%
%% -------------------------------------------------------------------
-module(mi_server).
-author("Rusty Klophaus <rusty@basho.com>").
-include("merge_index.hrl").

-export([
    get_id_number/1,
    has_deleteme_flag/1,
    set_deleteme_flag/1,
    register_buffer_converter/2,
    buffer_to_segment/3,
    %% GEN SERVER
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, { 
    root,
    locks,
    indexes,
    fields,
    terms,
    segments,
    buffers,
    next_id,
    is_compacting,
    buffer_converter,
    stream_range_pids,
    buffer_rollover_size
}).

-record(stream_range, {
          pid,
          caller,
          ref,
          buffers,
          segments
         }).

-define(RESULTVEC_SIZE, 1000).
-define(DELETEME_FLAG, ".deleted").

register_buffer_converter(ServerPid, ConverterPid) ->
    gen_server:cast(ServerPid, {register_buffer_converter, ConverterPid}).

buffer_to_segment(ServerPid, Buffer, SegmentWO) ->
    gen_server:cast(ServerPid, {buffer_to_segment, Buffer, SegmentWO}).

init([Root]) ->
    %% Seed the random generator...
    random:seed(now()),
    
    %% Load from disk...
    filelib:ensure_dir(join(Root, "ignore")),
    io:format("Loading merge_index from '~s'~n", [Root]),
    {NextID, Buffer, Segments} = read_buf_and_seg(Root),
    io:format("Finished loading merge_index from '~s'~n", [Root]),

    %% trap exits so compaction and stream/range spawned processes
    %% don't pull down this merge_index if they fail
    process_flag(trap_exit, true),

    %% Use a dedicated worker sub-process to do the 
    {ok, ConverterSup} = mi_buffer_converter:start_link(self(), Root),

    %% Create the state...
    State = #state {
        root     = Root,
        locks    = mi_locks:new(),
        buffers  = [Buffer],
        segments = Segments,
        next_id  = NextID,
        is_compacting = false,
        buffer_converter = {ConverterSup, undefined},
        stream_range_pids = [],
        buffer_rollover_size=fuzzed_rollover_size()
    },

    %% %% Do some profiling.
    %% eprof:profile([self()]),

    %% Return.
    {ok, State}.

%% Return {Buffers, Segments}, after cleaning up/repairing any partially merged buffers.
read_buf_and_seg(Root) ->
    %% Delete any files that have a ?DELETEME_FLAG flag. This means that
    %% the system stopped before proper cleanup.
    io:format("Cleaning up...~n"),
    F1 = fun(Filename) ->
        Basename = filename:basename(Filename, ?DELETEME_FLAG),
        Basename1 = filename:join(Root, Basename ++ ".*"),
        io:format("Deleting '~s'~n", [Basename1]),
        io:format("~p~n", [filelib:wildcard(Basename1)]),
        [ok = file:delete(X) || X <- filelib:wildcard(Basename1)]
    end,
    [F1(X) || X <- filelib:wildcard(join(Root, "*.deleted"))],

    %% Open the segments...
    SegmentFiles = filelib:wildcard(join(Root, "segment.*.data")),
    SegmentFiles1 = [filename:join(Root, filename:basename(X, ".data")) || X <- SegmentFiles],
    Segments = read_segments(SegmentFiles1, []),

    %% Get buffer files, calculate the next_id, load the buffers, turn
    %% any extraneous buffers into segments...
    BufferFiles = filelib:wildcard(join(Root, "buffer.*")),
    BufferFiles1 = lists:sort([{get_id_number(X), X} || X <- BufferFiles]),
    NextID = lists:max([X || {X, _} <- BufferFiles1] ++ [0]) + 1,
    {NextID1, Buffer, Segments1} = read_buffers(Root, BufferFiles1, NextID, Segments),
    
    %% Return...
    {NextID1, Buffer, Segments1}.

read_segments([], _Segments) -> [];
read_segments([SName|Rest], Segments) ->
    %% Read the segment from disk...
    io:format("Opening segment: '~s'~n", [SName]),
    Segment = mi_segment:open_read(SName),
    [Segment|read_segments(Rest, Segments)].

read_buffers(Root, [], NextID, Segments) ->
    %% No latest buffer exists, open a new one...
    BName = join(Root, "buffer." ++ integer_to_list(NextID)),
    io:format("Opening new buffer: '~s'~n", [BName]),
    Buffer = mi_buffer:new(BName),
    {NextID + 1, Buffer, Segments};

read_buffers(_Root, [{_BNum, BName}], NextID, Segments) ->
    %% This is the final buffer file... return it as the open buffer...
    io:format("Opening buffer: '~s'~n", [BName]),
    Buffer = mi_buffer:new(BName),
    {NextID, Buffer, Segments};

read_buffers(Root, [{BNum, BName}|Rest], NextID, Segments) ->
    %% Multiple buffers exist... convert them into segments...
    io:format("Converting buffer: '~s' to segment.~n", [BName]),
    SName = join(Root, "segment." ++ integer_to_list(BNum)),
    set_deleteme_flag(SName),
    Buffer = mi_buffer:new(BName),
    mi_buffer:close_filehandle(Buffer),
    SegmentWO = mi_segment:open_write(SName),
    mi_segment:from_buffer(Buffer, SegmentWO),
    mi_buffer:delete(Buffer),
    clear_deleteme_flag(mi_segment:filename(SegmentWO)),
    SegmentRO = mi_segment:open_read(SName),
    
    %% Loop...
    read_buffers(Root, Rest, NextID, [SegmentRO|Segments]).


handle_call({index, Postings}, _From, State) ->
    %% Write to the buffer...
    #state { buffers=[CurrentBuffer0|Buffers],
             buffer_converter={_,ConverterWorker},
             root=Root} = State,

    %% By multiplying the timestamp by -1 and swapping order of TS and
    %% props, we can take advantage of the natural ordering of
    %% postings, eliminating the need for custom sort Functions (which
    %% makes things much faster.) We only need to do the
    %% multiplication here, because these values carry through to
    %% segments. We also group {Index, Field, Term} into a key because
    %% this is what mi_buffer needs to write to ets. This is a leaky
    %% abstraction for the benefit of speed.
    F = fun({Index, Field, Term, Value, Props, Tstamp}) ->
                {{Index, Field, Term}, Value, -1 * Tstamp, Props}
        end,
    Postings1 = [F(X) || X <- Postings],
    CurrentBuffer = mi_buffer:write(Postings1, CurrentBuffer0),

    %% Update the state...
    NewState = State#state {buffers = [CurrentBuffer | Buffers]},

    %% Possibly dump buffer to a new segment. 
    case mi_buffer:filesize(CurrentBuffer) > State#state.buffer_rollover_size of
        true ->
            #state { next_id=NextID } = NewState,
            
            %% Close the buffer filehandle. Needs to be done in the owner process.
            mi_buffer:close_filehandle(CurrentBuffer),
            
            mi_buffer_converter:convert(
              ConverterWorker, Root, CurrentBuffer),
            
            %% Create a new empty buffer...
            BName = join(NewState, "buffer." ++ integer_to_list(NextID)),
            NewBuffer = mi_buffer:new(BName),
            
            NewState1 = NewState#state {
                buffers=[NewBuffer|NewState#state.buffers],
                next_id=NextID + 1,
                buffer_rollover_size = fuzzed_rollover_size()
            },
            {reply, ok, NewState1};
        false ->
            {reply, ok, NewState}
    end;

handle_call(start_compaction, _From, State) 
  when is_tuple(State#state.is_compacting) orelse length(State#state.segments) =< 5 ->
    %% Don't compact if we are already compacting, or if we have fewer
    %% than five open segments.
    {reply, {ok, 0, 0}, State};

handle_call(start_compaction, From, State) ->
    %% Get list of segments to compact. Do this by getting filesizes,
    %% and then lopping off files larger than the average. This could be
    %% optimized with tuning, but probably a good enough solution.
    Segments = State#state.segments,
    {ok, MaxSegments} = application:get_env(merge_index, max_compact_segments),
    SegmentsToCompact = case get_segments_to_merge(Segments) of
                            STC when length(STC) > MaxSegments ->
                                lists:sublist(STC, MaxSegments);
                            STC ->
                                STC
                        end,
    BytesToCompact = lists:sum([mi_segment:filesize(X) || X <- SegmentsToCompact]),
    
    %% Spawn a function to merge a bunch of segments into one...
    Pid = self(),
    CompactingPid = spawn_opt(fun() ->
        %% Create the group iterator...
        SegmentIterators = [mi_segment:iterator(X) || X <- SegmentsToCompact],
        GroupIterator = build_iterator_tree(SegmentIterators),

        %% Create the new compaction segment...
        <<MD5:128/integer>> = erlang:md5(term_to_binary({now, make_ref()})),
        SName = join(State, io_lib:format("segment.~.16B", [MD5])),
        set_deleteme_flag(SName),
        CompactSegment = mi_segment:open_write(SName),
        
        %% Run the compaction...
        mi_segment:from_iterator(GroupIterator, CompactSegment),
        gen_server:cast(Pid, {compacted, CompactSegment, SegmentsToCompact, BytesToCompact, From})
    end, [link, {fullsweep_after, 0}]),
    {noreply, State#state { is_compacting={From, CompactingPid} }};

%% Instead of count, return an actual weight. The weight will either
%% be 0 (if the term is in a block with other terms) or the size of
%% the block if the block is devoted to the index alone. This will
%% make query planning go as expected.
handle_call({info, Index, Field, Term}, _From, State) ->
    %% Calculate the IFT...
    #state { buffers=Buffers, segments=Segments } = State,

    %% Look up the weights in segments. 
    BufferCount = [mi_buffer:info(Index, Field, Term, X) || X <- Buffers],
    SegmentCount = [mi_segment:info(Index, Field, Term, X) || X <- Segments],
    TotalCount = lists:sum([0|BufferCount]) + lists:sum([0|SegmentCount]),
    Counts = [{Term, TotalCount}],
    
    %% Return...
    {reply, {ok, Counts}, State};

handle_call({stream, Index, Field, Term, Pid, Ref, FilterFun}, _From, State) ->
    %% Get the IDs...
    #state { locks=Locks, buffers=Buffers, segments=Segments } = State,

    %% Add locks to all buffers...
    F1 = fun(Buffer, Acc) ->
                 mi_locks:claim(mi_buffer:filename(Buffer), Acc)
         end,
    NewLocks = lists:foldl(F1, Locks, Buffers),

    %% Add locks to all segments...
    F2 = fun(Segment, Acc) ->
                 mi_locks:claim(mi_segment:filename(Segment), Acc)
         end,
    NewLocks1 = lists:foldl(F2, NewLocks, Segments),

    %% Spawn a streaming function...
    StreamPid = spawn_link(fun() ->
                       F = fun(Results) ->
                                   WrappedFilter = fun({Value, Props}) -> 
                                                           FilterFun(Value, Props) == true
                                                   end,
                                   case lists:filter(WrappedFilter, Results) of
                                       [] -> 
                                           skip;
                                       FilteredResults ->
                                           Pid ! {result_vec, FilteredResults, Ref}
                                   end
                           end,
                       try
                           stream(Index, Field, Term, F, Buffers, Segments)
                       catch Type : Error ->
                               ?PRINT({Type, Error, erlang:get_stacktrace()})
                       after
                           Pid ! {result, '$end_of_table', Ref}
                       end
               end),

    NewPids = [ #stream_range{pid=StreamPid,
                              caller=Pid,
                              ref=Ref,
                              buffers=Buffers,
                              segments=Segments}
                | State#state.stream_range_pids ],
    {reply, ok, State#state { locks=NewLocks1,
                              stream_range_pids=NewPids }};
    
handle_call({range, Index, Field, StartTerm, EndTerm, Size, Pid, Ref, FilterFun}, _From, State) ->
    #state { locks=Locks, buffers=Buffers, segments=Segments } = State,

    %% Add locks to all buffers...
    F1 = fun(Buffer, Acc) ->
                 mi_locks:claim(mi_buffer:filename(Buffer), Acc)
         end,
    NewLocks = lists:foldl(F1, Locks, Buffers),

    %% Add locks to all segments...
    F2 = fun(Segment, Acc) ->
                 mi_locks:claim(mi_segment:filename(Segment), Acc)
         end,
    NewLocks1 = lists:foldl(F2, NewLocks, Segments),

    RangePid = spawn_link(fun() ->
                       F = fun(Results) ->
                                   WrappedFilter = fun({Value, Props}) -> 
                                                           FilterFun(Value, Props) == true
                                                   end,
                                   case lists:filter(WrappedFilter, Results) of
                                       [] -> 
                                           skip;
                                       FilteredResults ->
                                           Pid ! {result_vec, FilteredResults, Ref}
                                   end
                           end,
                       range(Index, Field, StartTerm, EndTerm, Size, F, Buffers, Segments),
                       Pid ! {result, '$end_of_table', Ref}
               end),

    NewPids = [ #stream_range{pid=RangePid,
                              caller=Pid,
                              ref=Ref,
                              buffers=Buffers,
                              segments=Segments}
                | State#state.stream_range_pids ],
    {reply, ok, State#state { locks=NewLocks1,
                              stream_range_pids=NewPids }};
    
handle_call({fold, FoldFun, Acc}, _From, State) ->
    #state { buffers=Buffers, segments=Segments } = State,

    %% Wrap the FoldFun so that we have a chance to do IndexID /
    %% FieldID / TermID lookups
    WrappedFun = fun({Index, Field, Term, Value, TS, Props}, AccIn) ->
        %% Call the fold function. Undo the Timestamp inversion.
        FoldFun(Index, Field, Term, Value, Props, -1 * TS, AccIn)
    end,

    %% Fold through all the buffers...
    F1 = fun(Buffer, AccIn) -> 
                 Iterator = mi_buffer:iterator(Buffer),
                 fold(WrappedFun, AccIn, Iterator())
         end,
    Acc1 = lists:foldl(F1, Acc, Buffers),

    %% Fold through all the segments...
    F2 = fun(Segment, AccIn) -> 
                 Iterator = mi_segment:iterator(Segment),
                 fold(WrappedFun, AccIn, Iterator())
         end,
    Acc2 = lists:foldl(F2, Acc1, Segments),

    %% Reply...
    {reply, {ok, Acc2}, State};
    
handle_call(is_empty, _From, State) ->
    %% Check if we have buffer data...
    case State#state.buffers of
        [] -> 
            HasBufferData = false;
        [Buffer] ->
            HasBufferData = mi_buffer:size(Buffer) > 0;
        _ ->
            HasBufferData = true
    end,

    %% Check if we have segment data.
    HasSegmentData = length(State#state.segments) > 0,

    %% Return.
    IsEmpty = (not HasBufferData) andalso (not HasSegmentData),
    {reply, IsEmpty, State};

handle_call(drop, _From, State) ->
    #state { buffers=Buffers, segments=Segments } = State,

    %% Delete files, reset state...
    [mi_buffer:delete(X) || X <- Buffers],
    [mi_segment:delete(X) || X <- Segments],
    BufferFile = join(State, "buffer.1"),
    Buffer = mi_buffer:new(BufferFile),
    NewState = State#state { locks = mi_locks:new(),
                             buffers = [Buffer],
                             segments = [] },
    {reply, ok, NewState};

handle_call(Request, _From, State) ->
    ?PRINT({unhandled_call, Request}),
    {reply, ok, State}.

handle_cast({compacted, CompactSegmentWO, OldSegments, OldBytes, From}, State) ->
    #state { locks=Locks, segments=Segments } = State,

    %% Clean up. Remove delete flag on the new segment. Add delete
    %% flags to the old segments. Register to delete the old segments
    %% when the locks are freed.
    clear_deleteme_flag(mi_segment:filename(CompactSegmentWO)),

    %% Open the segment as read only...
    CompactSegmentRO = mi_segment:open_read(mi_segment:filename(CompactSegmentWO)),

    [set_deleteme_flag(mi_segment:filename(X)) || X <- OldSegments],
    F = fun(X, Acc) ->
        mi_locks:when_free(mi_segment:filename(X), fun() -> mi_segment:delete(X) end, Acc)
    end,
    NewLocks = lists:foldl(F, Locks, OldSegments),

    %% Update State and return...
    NewState = State#state {
        locks=NewLocks,
        segments=[CompactSegmentRO|(Segments -- OldSegments)],
        is_compacting=false
    },

    %% Tell the awaiting process that we've finished compaction.
    gen_server:reply(From, {ok, length(OldSegments), OldBytes}),
    {noreply, NewState};

handle_cast({buffer_to_segment, Buffer, SegmentWO}, State) ->
    #state { locks=Locks, buffers=Buffers, segments=Segments, is_compacting=IsCompacting } = State,

    %% Clean up by clearing delete flag on the segment, adding delete
    %% flag to the buffer, and telling the system to delete the buffer
    %% as soon as the last lock is released.
    clear_deleteme_flag(mi_segment:filename(SegmentWO)),
    BName = mi_buffer:filename(Buffer),
    set_deleteme_flag(BName),
    NewLocks = mi_locks:when_free(BName, fun() -> mi_buffer:delete(Buffer) end, Locks),

    %% Open the segment as read only...
    SegmentRO = mi_segment:open_read(mi_segment:filename(SegmentWO)),

    %% Update state...
    NewSegments = [SegmentRO|Segments],
    NewState = State#state {
        locks=NewLocks,
        buffers=Buffers -- [Buffer],
        segments=NewSegments
    },

    %% Give us the opportunity to do a merge...
    SegmentsToMerge = get_segments_to_merge(NewSegments),
    case length(SegmentsToMerge) of
        Num when Num =< 2 orelse is_tuple(IsCompacting) -> 
            ok;
        _ -> 
            mi_scheduler:schedule_compaction(self())
    end,
    {noreply, NewState};

handle_cast({register_buffer_converter, ConverterWorker},
            #state{buffer_converter={ConverterSup,_},
                   buffers=Buffers,
                   root=Root}=State) ->
    %% a new buffer converter started - queue all buffers but the
    %% current one for conversion to segments
    
    %% current buffer is hd(Buffers), so just convert tl(Buffers)
    [ mi_buffer_converter:convert(ConverterWorker, Root, B)
      || B <- tl(Buffers) ],

    {noreply, State#state{buffer_converter={ConverterSup, ConverterWorker}}};

handle_cast(Msg, State) ->
    ?PRINT({unhandled_cast, Msg}),
    {noreply, State}.

handle_info({'EXIT', CompactingPid, Reason},
            #state{is_compacting={From, CompactingPid}}=State) ->
    %% the spawned compaction process exited
    case Reason of
        normal ->
            %% compaction finished normally: nothing to be done
            %% handle_call({compacted... already sent the reply
            ok;
        _ ->
            %% compaction failed: not too much to worry about
            %% (it should be safe to try again later)
            %% but we need to let the compaction-requester know
            %% that we're not compacting any more
            gen_server:reply(From, {error, Reason})
    end,

    %% clear out compaction flags, so we try again when necessary
    {noreply, State#state{is_compacting=false}};
handle_info({'EXIT', ConverterSup, Reason},
            #state{buffer_converter={ConverterSup, _}}=State) ->
    %% if our converter's supervisor died, there's a problem: exit
    {stop, {buffer_converter_death, Reason}, State};

handle_info({'EXIT', Pid, Reason},
            #state{stream_range_pids=SRPids}=State) ->

    case lists:keytake(Pid, #stream_range.pid, SRPids) of
        {value, SR, NewSRPids} ->
            %% One of our stream or range processes exited

            case Reason of
                normal ->
                    %% we've already sent the end-of-table message
                    ok;
                _Error ->
                    %% send the end-of-table so the listener exits
                    SR#stream_range.caller !
                        {result, '$end_of_table', SR#stream_range.ref}
            end,

            %% Remove locks from all buffers...
            F1 = fun(Buffer, Acc) ->
                mi_locks:release(mi_buffer:filename(Buffer), Acc)
            end,
            NewLocks = lists:foldl(F1, State#state.locks,
                                   SR#stream_range.buffers),

            %% Remove locks from all segments...
            F2 = fun(Segment, Acc) ->
                mi_locks:release(mi_segment:filename(Segment), Acc)
            end,
            NewLocks1 = lists:foldl(F2, NewLocks,
                                   SR#stream_range.segments),

            {noreply, State#state { locks=NewLocks1,
                                    stream_range_pids=NewSRPids }};
        false ->
            %% some random other process exited: ignore
            {noreply, State}
    end;

handle_info(Info, State) ->
    ?PRINT({unhandled_info, Info}),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Merge-sort the results from Iterators, and stream to the pid.
stream(Index, Field, Term, F, Buffers, Segments) ->
    %% Put together the group iterator...
    BufferIterators = [mi_buffer:iterator(Index, Field, Term, X) || X <- Buffers],
    SegmentIterators = [mi_segment:iterator(Index, Field, Term, X) || X <- Segments],
    GroupIterator = build_iterator_tree(BufferIterators ++ SegmentIterators),

    %% Start streaming...
    stream_or_range_inner(F, undefined, GroupIterator(), []),
    ok.

range(Index, Field, StartTerm, EndTerm, Size, F, Buffers, Segments) ->
    %% Put together the group iterator...
    BufferIterators = lists:flatten([mi_buffer:iterators(Index, Field, StartTerm, EndTerm, Size, X) || X <- Buffers]),
    SegmentIterators = lists:flatten([mi_segment:iterators(Index, Field, StartTerm, EndTerm, Size, X) || X <- Segments]),
    GroupIterator = build_iterator_tree(BufferIterators ++ SegmentIterators),

    %% Start rangeing...
    stream_or_range_inner(F, undefined, GroupIterator(), []),
    ok.

stream_or_range_inner(F, LastValue, Iterator, Acc) 
  when length(Acc) > ?RESULTVEC_SIZE ->
    F(lists:reverse(Acc)),
    stream_or_range_inner(F, LastValue, Iterator, []);
stream_or_range_inner(F, LastValue, {{Value, _TS, Props}, Iter}, Acc) ->
    IsDuplicate = (LastValue == Value),
    IsDeleted = (Props == undefined),
    case (not IsDuplicate) andalso (not IsDeleted) of
        true  -> 
            stream_or_range_inner(F, Value, Iter(), [{Value, Props}|Acc]);
        false -> 
            stream_or_range_inner(F, Value, Iter(), Acc)
    end;
stream_or_range_inner(F, _, eof, Acc) -> 
    F(lists:reverse(Acc)),
    ok.

%% Chain a list of iterators into what looks like one single
%% iterator. 
build_iterator_tree([]) ->
    fun() -> eof end;
build_iterator_tree(Iterators) ->
    case build_iterator_tree_inner(Iterators) of
        [OneIterator] -> OneIterator;
        ManyIterators -> build_iterator_tree(ManyIterators)
    end.
build_iterator_tree_inner([]) ->
    [];
build_iterator_tree_inner([Iterator]) ->
    [Iterator];
build_iterator_tree_inner([IteratorA,IteratorB|Rest]) ->
    Iterator = fun() -> group_iterator(IteratorA(), IteratorB()) end,
    [Iterator|build_iterator_tree_inner(Rest)].

%% group_iterator_term/2 - Combine two iterators into one iterator.
group_iterator(I1 = {Term1, Iterator1}, I2 = {Term2, Iterator2}) ->
    case Term1 < Term2 of
        true ->
            NewIterator = fun() -> group_iterator(Iterator1(), I2) end,
            {Term1, NewIterator};
        false ->
            NewIterator = fun() -> group_iterator(I1, Iterator2()) end,
            {Term2, NewIterator}
    end;
group_iterator(eof, eof) -> 
    eof;
group_iterator(eof, Iterator) -> 
    Iterator;
group_iterator(Iterator, eof) -> 
    Iterator.

%% Return the ID number of a Segment/Buffer/Filename...
%% Files can be named:
%%   - buffer.N
%%   - segment.N
%%   - segment.N.data
%%   - segment.M-N
%%   - segment.M-N.data
get_id_number(Segment) when element(1, Segment) == segment ->
    Filename = mi_segment:filename(Segment),
    get_id_number(Filename);
get_id_number(Buffer) when element(1, Buffer) == buffer ->
    Filename = mi_buffer:filename(Buffer),
    get_id_number(Filename);
get_id_number(Filename) ->
    case string:chr(Filename, $-) == 0 of
        true ->
            %% Handle buffer.N, segment.N, segment.N.data
            case string:tokens(Filename, ".") of
                [_, N]    -> ok;
                [_, N, _] -> ok
            end,
            list_to_integer(N);
        false ->
            %% Handle segment.M-N, segment.M-N.data
            case string:tokens(Filename, ".-") of
                [_, M, N]    -> ok;
                [_, M, N, _] -> ok
            end,
            [list_to_integer(M), list_to_integer(N)]
    end.

set_deleteme_flag(Filename) ->
    file:write_file(Filename ++ ?DELETEME_FLAG, "").

clear_deleteme_flag(Filename) ->
    file:delete(Filename ++ ?DELETEME_FLAG).

has_deleteme_flag(Filename) ->
    filelib:is_file(Filename ++ ?DELETEME_FLAG).

%% Figure out which files to merge. Take the average of file sizes,
%% return anything smaller than the average for merging.
get_segments_to_merge(Segments) ->
    %% Get all segment sizes...
    F1 = fun(X) ->
        Size = mi_segment:filesize(X),
        {Size, X}
    end,
    SortedSizedSegments = lists:sort([F1(X) || X <- Segments]),
    
    %% Calculate the average...
    Avg = lists:sum([Size || {Size, _} <- SortedSizedSegments]) div length(Segments) + 1024,

    %% Return segments less than average...
    [Segment || {Size, Segment} <- SortedSizedSegments, Size < Avg].

fold(_Fun, Acc, eof) -> 
    Acc;
fold(Fun, Acc, {Term, IteratorFun}) ->
    fold(Fun, Fun(Term, Acc), IteratorFun()).

join(#state { root=Root }, Name) ->
    join(Root, Name);

join(Root, Name) ->
    filename:join([Root, Name]).

%% Add some random variation (plus or minus 25%) to the rollover size
%% so that we don't get all buffers rolling over at the same time.
fuzzed_rollover_size() ->
    ActualRolloverSize = element(2,application:get_env(merge_index, buffer_rollover_size)),
    mi_utils:fuzz(ActualRolloverSize, 0.25).
