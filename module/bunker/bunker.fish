function bunker_code_encounter
    set -l n 100
    set -l i (builtin random 1 $n)

    if test $i -ne $n
        return
    end

    set --export -g _bunker_code (new-bunker-code)

    printf '\e[1;33m[A piece of paper drifts by you in the wind]\e[0m\n'
end

function bunker_encounter
    set -l n 150
    set -l i (builtin random 1 $n)

    if test $i -ne $n
        return
    end

    set --export -g BUNKER_ENCOUNTER true

    printf '\e[1;33m[You find a strange door in the mountainside]\e[0m\n'
end

function bunker_hook --on-event fish_postexec
    bunker_code_encounter
    bunker_encounter
end

function read-bunker-code
    if not set -q _bunker_code
        return 1
    end

    printf '%s\n' "$_bunker_code"
    set -e _bunker_code
end

function visit-bunker
    visit-bunker-impl
    set --local my_exit_status $status
    set -e -g BUNKER_ENCOUNTER
    return $my_exit_status
end
