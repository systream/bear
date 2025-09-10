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
-export([init/1, handle_event/4, terminate/3]).


init(Args) ->
  io:format(user, "init: ~p~n", [Args]),
  {ok, wait, #{}}.

handle_event({call, From}, {set, NewData}, _CurrentState, _Data) ->
  io:format(user, "set ~p state to ~p~n", [self(), NewData]),
  {keep_state, NewData, [save, {reply, From, ok}]};

handle_event(Event, EventContext, CurrentState, Data) ->
  io:format(user, "event: ~p~nEventContect: ~p~nCStatte:~p~nData:~p~n***~n",
    [Event, EventContext, CurrentState, Data]),
  keep_state_and_data.

terminate(Reason, CurrentState, Data) ->
  io:format("Reason: ~p Current state: ~p Data: ~p~n", [Reason, CurrentState, Data]),
  ok.