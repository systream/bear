-module(bear_pmap).

%% API
-export([execute/2]).

-spec execute(fun((term()) -> term()), [term()]) -> [term()].
execute(Fun, List) ->
  S = self(),
  Refs = [spawn_monitor(fun() -> S ! {self(), Fun(Item)} end) || Item <- List],
  await(Refs, []).

await([{Pid, MRef} | Rest], Acc) ->
  receive
    {'DOWN', MRef, process, Pid, Reason} ->
      await(Rest, [{error, Reason} | Acc]);
    {Pid, Res} ->
      erlang:demonitor(MRef, [flush]),
      await(Rest, [Res | Acc])
  end;
await([], Acc) ->
  lists:reverse(Acc).
