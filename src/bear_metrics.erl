%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. nov. 2025 10:56
%%%-------------------------------------------------------------------
-module(bear_metrics).

-define(SPIRAL_TIME_SPAN, 16000).
-define(SPIRAL_OPTS, [{slot_period, 1000},
                       {time_span, ?SPIRAL_TIME_SPAN}]).

-define(BASE, bear).

%% API
-export([init/0, update/2, count/1, decrease/1, increase/1, stat/0]).

-spec init() -> ok.
init() ->
  ok = exometer:ensure([?BASE, statem, active], counter, []),
  ok = exometer:ensure([?BASE, statem, started], spiral, ?SPIRAL_OPTS),
  ok = exometer:ensure([?BASE, statem, handoff], spiral, ?SPIRAL_OPTS).

-spec update([atom()], number()) -> ok.
update(Name, Value) ->
  ok = exometer:update([?BASE | Name], Value).

-spec count([atom()]) -> ok.
count(Name) ->
  update(Name, 1).

-spec increase([atom()]) -> ok.
increase(Name) ->
  update(Name, 1).

-spec decrease([atom()]) -> ok.
decrease(Name) ->
  update(Name, -1).

-spec stat() -> [{list(atom()), number()}].
stat() ->
  {ok, [{value, ActiveCount}]} = exometer:get_value([?BASE, statem, active], value),
  {ok, [{one, Started}]} = exometer:get_value([?BASE, statem, started], one),
  {ok, [{one, Handoff}]} = exometer:get_value([?BASE, statem, handoff], one),
  [
    {[statem, active], ActiveCount},
    {[statem, started], Started div (?SPIRAL_TIME_SPAN div 1000)},
    {[statem, handoff], Handoff div (?SPIRAL_TIME_SPAN div 1000)}
  ].
