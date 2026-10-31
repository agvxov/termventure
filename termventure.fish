# termventure.fish -- SWP consumer

set -l path (dirname (realpath (status filename)))

set -g __swp_sock $path/internal/termventure.sock

# --- transport -------------------------------------------------------------
# One short-lived socat connection per command.
function __swp_send --argument-names line
    printf '%s\n' $line | socat -T 1 - UNIX-CONNECT:$__swp_sock >/dev/null 2>&1
end

function __swp_ask --argument-names line
    printf '%s\n' $line | socat -T 1 - UNIX-CONNECT:$__swp_sock 2>/dev/null
end

# --- protocol --------------------------------------------------------------

function swp_bump
    __swp_send '<'
end

function swp_conf
    __swp_send "? "(string replace -a \n ' ' -- "$argv")
end

function swp_poll
    set script (__swp_ask '=')
    if test -z $script
        return
    end

    set --local --export PATH "$TERMVENTURE_PATH:$PATH"

    for line in $script
        switch (string sub -l 1 -- $line)
            case '>'
                eval (string sub -s 3 -- $line)
            case '-'
            case '*'
        end
    end
end

# --- daemon lifecycle ------------------------------------------------------

if not test -S $__swp_sock
    # launch and detach
    $path/internal/termventure-daemon.pl </dev/null >/dev/null 2>&1 &
    disown $last_pid

    for i in (seq 40)
        test -S $__swp_sock; and break
        sleep 0.01
    end
end

# --- --- ---

set --global --export --append PATH "$path/internal"

swp_conf PATH
swp_poll
swp_conf ""

function __swp_postexec --on-event fish_postexec
    swp_bump
    swp_poll
end

function god-mode
    set --global --export PATH "$TERMVENTURE_PATH:$PATH"
end
