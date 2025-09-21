%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(bear_backend).
-author("tihi").

-type bucket() :: binary().
-type key() :: binary().
-type data() :: binary().

-type obj() :: riakc_obj:riakc_obj().

-export_type([bucket/0, key/0, data/0, obj/0]).

%% API
-export([store/1, fetch/2, value/1, new_obj/3, value/2, store/3, remove/1]).

-spec store(bucket(), key(), data()) -> {ok, obj()} | {error, term()}.
store(Bucket, Key, Data) ->
  case fetch(Bucket, Key) of
    {ok, Obj} ->
      store(value(Obj, Data));
    not_found ->
      store(new_obj(Bucket, Key, Data));
    Else ->
      Else
  end.

-spec store(obj()) -> {ok, obj()} | {error, term()}.
store(Obj) ->
  execute(fun riakc_pb_socket:put/3, [Obj, [return_body]]).

-spec fetch(bucket(), key()) -> {ok, obj()} | not_found | {error, term()}.
fetch(Bucket, Key) ->
  case execute(fun riakc_pb_socket:get/3, [Bucket, Key]) of
    {error, notfound} ->
      not_found;
    Else ->
      Else
  end.

-spec remove(obj()) -> ok | {error, term()}.
remove(Obj) ->
  execute(fun riakc_pb_socket:delete_obj/2, [Obj]).

-spec value(obj()) -> data().
value(Obj) ->
  riakc_obj:get_value(Obj).

-spec value(obj(), data()) -> obj().
value(Obj, NewData) ->
  riakc_obj:update_value(Obj, NewData).

-spec new_obj(bucket(), key(), data()) -> obj().
new_obj(Bucket, Key, Value) ->
  riakc_obj:new(Bucket, Key, Value).

execute(Fun, Args) ->
  Pid = bear_pool:checkout(),
  MaxRetry = application:get_env(bear, max_retry, 2),
  Result = retry_wrap(Fun, [Pid | Args], MaxRetry),
  bear_pool:checkin(Pid),
  Result.

retry_wrap(Fun, Args, MaxRetry) ->
  case apply(Fun, Args) of
    {error, disconnected} when MaxRetry >= 0 ->
      [Pid | RemArgs] = Args,
      timer:sleep(rand:uniform(5)),
      NewPid = bear_pool:checkout(),
      bear_pool:checkin(Pid),
      retry_wrap(Fun, [NewPid | RemArgs], MaxRetry-1);
    Else ->
      Else
  end.