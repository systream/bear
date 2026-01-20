# Bear

Bear is a distributed state machine manager for Erlang/OTP. It provides a robust way to manage stateful processes across a cluster using consistent hashing for distribution and `pes` for process registry and discovery.

## Features

- **Distributed State Management**: Automatically distributes `gen_statem` processes across the cluster.
- **Consistent Hashing**: Ensures even distribution of processes and minimizes reshuffling when nodes leave or join.
- **Automatic Handoff**: Supports migrating processes between nodes during topology changes.
- **Cluster Awareness**: Integrated with `pes` and `simple_gossip` for cluster membership and failure detection.
- **Load Balancing**: Tools to drain nodes or rebalance handlers explicitly.

## Prerequisites

- Erlang/OTP 26 or later
- [rebar3](https://www.rebar3.org/)

## Build

To compile the project:

```bash
rebar3 compile
```

To create a release:

```bash
rebar3 release
```

## Usage

### Starting a State Machine

You can start a distributed state machine using `bear:start_link/3`:

```erlang
-module(my_handler).
-behaviour(bear).

%% API
-export([start/1, init/1, handle_event/4, terminate/3]).

start(Id) ->
    bear:start_link(Id, ?MODULE, [Id]).

init([Id]) ->
    {ok, handle_event_function, #{id => Id}}.

handle_event({call, From}, get_id, _StateName, Data) ->
    {keep_state_and_data, [{reply, From, maps:get(id, Data)}]};
handle_event(_Event, _Content, _StateName, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.
```

### API Reference

#### `bear:start_link(Id, Module, Args)`

Starts a new state machine on the cluster. The actual node is determined by consistent hashing of `Id`.

- `Id`: Unique identifier for the state machine.
- `Module`: Callback module implementing `gen_statem` behavior (via `bear` behavior).
- `Args`: Arguments passed to `init`.

#### `bear:call(Id, Request)`

Sends a synchronous call to the state machine identified by `Id`.

#### `bear:cast(Id, Request)`

Sends an asynchronous cast to the state machine identified by `Id`.

#### `bear:stop(Id)`

Stops the state machine identified by `Id`.

#### `bear:distribute_handlers()`

Triggers a manual redistribution of handlers across the cluster. Useful after adding new nodes.

### Testing

Run the test suite using rebar3:

```bash
rebar3 test
```

This acts as an alias running `ct` (Common Test), `proper` (Property-based testing), and `dialyzer`.
