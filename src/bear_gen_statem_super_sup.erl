-module(bear_gen_statem_super_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
          start_child/3,
          children/0,
          start_handoff/2,
          terminate_child/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

start_child(Id, Module, Args) ->
  bear_gen_statem_sup:start_child(get_supervisor_for_id(Id), Id, Module, Args).

terminate_child(Id) ->
  bear_gen_statem_sup:terminate_child(get_supervisor_for_id(Id), Id).

start_handoff(Id, Module) ->
  start_child(Id, Module, undefined).

children() ->
  lists:flatten([bear_gen_statem_sup:children(Server) || Server <- get_servers()]).

%% @doc Starts the supervisor
-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

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
  MaxRestarts = 10,
  MaxSecondsBetweenRestarts = 60,
  SupFlags = #{strategy => one_for_one,
    intensity => MaxRestarts,
    period => MaxSecondsBetweenRestarts},

  {ok, {SupFlags, [
    #{id => Name,
      start => {'bear_gen_statem_sup', start_link, [Name]},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => ['bear_gen_statem_sup', 'bear_gen_statem_handler']} || Name <- get_servers()]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec get_supervisor_for_id(term()) -> atom().
get_supervisor_for_id(Id) ->
  get_shard_name(erlang:phash2(Id, get_shard_count()) + 1).

get_shard_count() ->
  application:get_env(bear, supervisor_shard_count, 16).

get_shard_name(Id) ->
  list_to_atom("bear_gen_statem_sup_" ++ integer_to_list(Id)).

get_servers() ->
  [get_shard_name(Shard) || Shard <- lists:seq(1, get_shard_count())].