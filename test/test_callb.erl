%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 10. szept. 2025 18:08
%%%-------------------------------------------------------------------
-module(test_callb).
-author("tihi").

-behaviour(bear).

%% API
-export([set_state/2, check/0,  start/2, connect/0]).

-export([init/1, handle_event/4, terminate/3]).

connect() ->
  Node = node(),
  case atom_to_list(Node) of
    [$1 | Rem] -> %first node, than connect to the second one
      pes:join(list_to_atom("2" ++ Rem));
    [_ | Rem] ->
      pes:join(list_to_atom("1" ++ Rem))
  end.

start(Num, Concurrency) ->
  ItemPerNode = Num div Concurrency,
  FirstNodeExtra = Num rem Concurrency,
  spawn_monitor(fun() -> do_start(1, ItemPerNode+FirstNodeExtra) end),
  StartItem = ItemPerNode+FirstNodeExtra,
  lists:foldl(fun(_, IStartItem) ->
                  spawn_monitor(fun() -> do_start(IStartItem+1, ItemPerNode) end),
                  IStartItem+ItemPerNode
              end, StartItem, lists:seq(2, Concurrency)).

do_start(Start, Num) ->
  io:format(user, "starting ~p -> ~p (~p)~n", [Start, Start+Num, Num]),
  [bear_gen_statem_manager:start_handler(<<"test_", (id(I))/binary>>, test_callb, [I+I]) || I <- lists:seq(Start, Start+Num)].


set_state(Num, Concurrency) ->
  ItemPerNode = Num div Concurrency,
  FirstNodeExtra = Num rem Concurrency,
  spawn_monitor(fun() -> do_set_state(0, ItemPerNode+FirstNodeExtra) end),
  StartItem = ItemPerNode+FirstNodeExtra,
  lists:foldl(fun(_, IStartItem) ->
    spawn_monitor(fun() -> do_set_state(IStartItem, ItemPerNode) end),
    IStartItem+ItemPerNode
              end, StartItem, lists:seq(1, Concurrency)).

do_set_state(Start, Num) ->
  [catch gen_statem:call({via, pes, <<"test_", (id(I))/binary>>}, {set, {node(), self(), erlang:unique_integer(), integer_to_binary(I+I*I)}}) || I <- lists:seq(Start, Start+Num)].

check() ->
  Nodes = nodes([this, visible]),
  Result = pmap(fun(Node) ->
    {Node,
      extract_ids(rpc:call(Node, bear_gen_statem_sup, children, []))
    } end, Nodes),
  Diff = pmap(fun({Node, Ids}) ->
              CompareAgainst = proplists:delete(Node, Result),
              {Node, lists:map(fun({CNode, CIds}) ->
                                    {CNode, same_elements(Ids, CIds)}
                                  end, CompareAgainst)}
              end, Result),
  Counts = pmap(fun({Node, C}) -> {Node, length(C)} end,  Result),
  [{diff, Diff},
   {counts, Counts},
   {sum, lists:foldl(fun({_N, C}, A) -> C+A end, 0, Counts)}].

extract_ids(Child) ->
  lists:sort([Id || {Id, _, _} <- Child]).

pmap(Fun, List) ->
  S = self(),
  Refs = [spawn_monitor(fun() -> S ! {self(), Fun(Item)} end) || Item <- List],
  await(Refs, []).

await([{Pid, MRef} | Rest], Acc) ->
  receive
    {'DOWN', MRef, process, Pid, Reason} ->
      await(Rest, [{error, Reason} | Acc]);
    {Pid, Res} -> await(Rest, [Res | Acc])
  end;
await([], Acc) ->
  lists:reverse(Acc).

id(Num) ->
  <<"test_", (integer_to_binary(Num))/binary>>.

same_elements(L1, L2) ->
  lists:foldl(fun(I, A) ->
   case lists:member(I, L2) of
     true ->
       [I | A];
     _ ->
       A
   end end, [], L1).

init(_Args) ->
  %io:format(user, "init: ~p~n", [_Args]),
  {ok, wait, #{}}.

handle_event({call, From}, {set, NewData}, _CurrentState, _Data) ->
  io:format(user, "set ~p state to ~p~n", [self(), NewData]),
  {keep_state, NewData, [save, {reply, From, ok}]};

handle_event(_Event, _EventContext, _CurrentState, _Data) ->
  %io:format(user, "event: ~p~nEventContect: ~p~nCStatte:~p~nData:~p~n***~n",
  %  [_Event, _EventContext, _CurrentState, _Data]),
  keep_state_and_data.

terminate(Reason, CurrentState, Data) ->
  io:format("Reason: ~p Current state: ~p Data: ~p~n", [Reason, CurrentState, Data]),
  ok.