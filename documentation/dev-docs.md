# Developer Documentation

## Architecture
1. shell initializes daemon
2. shell bumps the daemon after commands
3. daemon rolls for events which are executable names
4. shell runs event executables
5. event executables communicate through core helpers

---

## Core helpers
| Helper          | Description                                    |
| :-------------- | :--------------------------------------------- |
| give-item       | Place an item in the user's inventory.         |
| has-item        | Determine if a player has a specific item.     |
| view-inventory  | Fetch a list of all items owned by the player. |
| termventure-get | Get value from registry.                       |
| termventure-set | Set value in registry.                         |

---

## Core scripts
| Script                | Description                       |
| :-------------------- | :-------------------------------- |
| termventure.fish      | Fish shell entry point. Sourced.  |
| termventure-daemon.pl | Event dispatcher. One per player. |

---

## Inventory
Responsible for all long term storage.

It has one item per line.

Each serialized item has the form:
```bnf
item : name
     | name # data

name : [-A-Za-z0-9]+

data : { pairs }

pairs : pair ; pairs
      | pair

pair : key : value

key : name

value : .*
```

E.g.:
```
stone
fire-sword#{damage:12;effect:fire}
```

### Item
An item could be anything.
Modules define their own items and give it arbitrary metadata.

However,
the name of the item will be used for texture lookups.

Item textures always end with `.ascii`
and may contain embedded VT escape sequences.

Say "stone" corresponds `stone.ascii`,
somewhere in the item search path.

---

## Registry
The registry is responsible for all short term storage.

Modules can query their loaded configuration from the registry
and can use it for IPC.

Currently implemented as a SQLitedb.

It is sectioned exactly like the configuration files are.

E.g.:
```sh
# script-foo
termventure-set "rabbit-game" "wild-rabbit" "{ 'fluffiness' => 10 }"
#               ^^^^^^^^^^^^^ ^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^
#                  section         key               value

# script-bar
VALUE=$(termventure-get "rabbit-game" "wild-rabbit")
```

---

## Configuration
Configuration is done through ini.

All section names are treated as names of modules which must be loaded,
Except any section name ending with `-disabled`,
which are ignored and load no module.

Modules may define arbitrary keys
and the RHS may be encoded and interpreted as most appropriate.

The core configuration is `termimon.ini` and is read first.

Core configuration values beat module configurations.
The module configurations shall be treated as the default/fallback value.

Modules can but should not define values in sections other their own.

### trigger
The trigger key is a special configuration value.

It signals to the daemon how often a script should be ran.

You can use triggers to create random events/encounters.

E.g.
```ini
[termimon]
trigger = { "termimon-encounter" => 600 }
```

The RHS is a Perl Hash literal.
The hash key is a command name,
the value is the 1:N probability to fire.

The example literally means:
"make the shell call termimon-encounter
with the odds of 1 out of 600 after every completed command".

---

## Daemon
The daemon is responsible for offloading computation from the shell,
such to prevent it from morphing into a slug.

The first shell starts the daemon.

All shell startups query information from the daemon,
such as "how should I amend my PATH?".

The shells post-exec hook queries the daemon for new events.

The shell and the daemon exchange data using a UNIX socket
and the Simple Worker Protocol ([SWP](swp.md)).
SWP is not used asynchronously,
from the shell,
every Bump is immediately followed by Poll
and must recieve a Push response from the daemon.
The response is then eval'd by the shell.
E.g. during start up,
environment variables could be passed upwards;
fired triggers are communicated passed as the executable names.

---

## Modules
Each module implements one or more game mechanics.

Modules shall only depend on Core when possible.

Modules shall not have cross-dependencies.

> [!NOTE]
> A hello-world style example can be found at
> [/modules/example](../module/example/) for your reference.

### Core
At the top-level of Termventure lives what we call the Core module.
It is essentially the skeleton of the project,
without which it does not exist,
whoever it should still be treated for the most part as if it was a regular module.

### Layout
Modules have a conventional layout.
Some of it is hardcoded into the daemon, some of it is not.

| Path         | Description  |
| :----------- | :----------- |
| item/        | Item search path. Item dirs are lumped together during lookups. Can contain nested dirs. |
| $module.ini  | Module specific configuration file. |
| user-action/ | Public player scripts. Added to `$PATH`. |
| internal/    | Private helper scripts. Not exposed to the user, but stored in `$TERMVENTURE_PATH` and in `$PATH` from module scripts. |
