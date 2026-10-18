# Simple Worker Protocol
> Super-simple protocol for continuous, asymmetric computation delegation

## Overview
The Simple Worker Protocol -or SWP for short- defines a small set
of commands and responses which are sufficient for remote computation.

It is continuous, the worker is expected to compute results repeatedly.

It is asymmetric, the consumer initiates all communication.

SWP is minimalistic and has no dedicated purpose.
As of now, it is used to provide responsive auto-completion for editors.

## Commands
A command is either a request or a response.
All SWP communication is done through commands.

Line based. UNIX line endings are used.

   <prefix> [payload] \n

| Prefix | Name | Consumer-sent? | Worker-sent? | Expects-response? | Has-argument? | Description |
| -----: | :--- | -------------: | -----------: | ----------------: | ------------: | :---------- |
|      < | Bump | yes            | no           | no                | no            | Signals that some shared resource has changed. |
|      ? | Conf | yes            | no           | no                | yes           | Sends a configuration update. |
|      = | Poll | yes            | no           | Yes               | no            | Requests the results. |
|      - | Pass | no             | yes          | no                | no            | Signals that the results are not ready yet. |
|      > | Push | no             | yes          | no                | yes           | Sends the results. |

```text
  +----------+    +--------+
  | Consumer |    | Worker |
  +----------+    +--------+
       -              <
       >              ?
                      =
```

## Notes
It is recommended to push as much information to the worker on start-up as possible.
A worker has no way of signaling an internal error,
therefor all configurations should map to a valid response.

## Usage in editors
When I say "editors", what I really mean is Vim,
and again, it is used for completions.

The worker is implemented as a Python server monitoring an UNIX socket handed to it on start-up.
It is also aware of a `ctags` database, Bump loads it.
A Conf sends the current text before the cursor, ie. the completion prefix.
