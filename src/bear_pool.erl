%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(bear_pool).

-define(DEFAULT_POOL_SIZE, 3).
-define(POOL_NAME, riak_pool).

%% API
-export([start_link/1, child_spec/0, checkout/0, checkin/1]).

child_spec() ->
  PoolArgs = [{name, {local, ?POOL_NAME}},
              {worker_module, ?MODULE},
              {size, application:get_env(bear, riak_pool_size, ?DEFAULT_POOL_SIZE)},
              {max_overflow, 0},
              {strategy, fifo}],
  poolboy:child_spec(?POOL_NAME, PoolArgs, []).

start_link(_) ->
  Host = os:getenv("RIAK_HOST", application:get_env(bear, riak_host, "127.0.0.1")),
  Port = list_to_integer(os:getenv("RIAK_PORT", application:get_env(bear, riak_port, "8087"))),
  User = os:getenv("RIAK_USER", application:get_env(bear, riak_user, "bear")),
  Pass = os:getenv("RIAK_PW",  application:get_env(bear, riak_port, "bear")),
  CertDir = code:priv_dir(bear),
  io:format(user, "User ~p connecting to ~p on ~p~n", [User, Host, Port]),
  riakc_pb_socket:start_link(Host, Port, [{auto_reconnect, true},
                                          {keepalive, true},
                                          {credentials, User, Pass},
                                          {cacertfile, filename:join([CertDir, "rootCA.crt"])},
                                          {certfile, filename:join([CertDir, "bear.crt"])},
                                          {keyfile, filename:join([CertDir, "bear.key"])}
    ,
    {ssl_opts, [
      {server_name_indication, Host},
      {customize_hostname_check, [
        {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
      ]}
    ]}

  ]).
-spec checkout() -> pid().
checkout() ->
  poolboy:checkout(?POOL_NAME, true).

-spec checkin(pid()) -> ok.
checkin(Pid) ->
  poolboy:checkin(?POOL_NAME, Pid).