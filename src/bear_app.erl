%%%-------------------------------------------------------------------
%% @doc bear public API
%% @end
%%%-------------------------------------------------------------------

-module(bear_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = bear_metrics:init(),
    bear_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
