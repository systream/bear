%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(bear_gen_statem_sup).

-behaviour(supervisor).

%% API
-export([start_link/1,
         start_child/4,
         children/1,
         terminate_child/2]).

%% Supervisor callbacks
-export([init/1]).

%%%===================================================================
%%% API functions
%%%===================================================================

start_child(Server, Id, Module, Args) ->
  case supervisor:start_child(Server, child_spec(Id, Module, Args)) of
    {error, already_present} ->
      supervisor:delete_child(Server, Id),
      start_child(Server, Id, Module, Args);
    {error, {already_started, Pid}} ->
      {ok, Pid};
    Else ->
      Else
  end.

terminate_child(Server, Id) ->
  case supervisor:terminate_child(Server, Id) of
    ok ->
      supervisor:delete_child(Server, Id);
    Else ->
      Else
  end.

children(Server) ->
  [{Id, Pid, Modules} ||
    {Id, Pid, worker, [bear_gen_statem_handler | Modules]}
      <- supervisor:which_children(Server), Pid =/= undefined].

%% @doc Starts the supervisor
-spec(start_link(atom()) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Id) ->
  supervisor:start_link({local, Id}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%% @private
%% @doc Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
-spec(init(Args :: term()) ->
  {'ok', {#{'intensity' := pos_integer(),
            'period' := pos_integer(),
            'strategy' := 'one_for_one'}, []}}).
init([]) ->
  MaxRestarts = 10000,
  MaxSecondsBetweenRestarts = 60,
  SupFlags = #{strategy => one_for_one,
               intensity => MaxRestarts,
               period => MaxSecondsBetweenRestarts},

  {ok, {SupFlags, []}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

child_spec(Name, Module, Args) ->
  #{id => Name,
    start => {'bear_gen_statem_handler', start_link, [Name, Module, Args]},
    restart => temporary,
    shutdown => 250000,
    type => worker,
    modules => ['bear_gen_statem_handler', Module]}.