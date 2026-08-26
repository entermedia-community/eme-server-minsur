#!/bin/bash

if [ -f ".env" ]; then
    export $(grep -v '^#' .env | xargs)
fi

if [ -z "$LISTOFPLUGINS" ]; then
    echo "ERROR: LISTOFPLUGINS is not set. Please set it in the .env file." >&2
    exit 1
fi

set -e

##pull 
##push "Message"
##or no argument to see all


##get the path from the current script
SERVERHOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IFS='|' read -r -a plugins <<< "$LISTOFPLUGINS"

CMD="$1"

##track if any changes were made to any of the plugins
FOUNDPENDING=false

safe_fetch_main() {
    if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
        git fetch --unshallow origin main
    else
        git fetch origin main
    fi
}

##sets $repo and $branch from plugins/<plugin>.json
load_plugin_config() {
    local plugin="$1"
    local configfile="$SERVERHOME/plugins/$plugin.json"

    repo=$(jq -r '.repo' "$configfile")
    branch=$(jq -r '.branch // "main"' "$configfile")

    if [ -z "$repo" ] || [ "$repo" == "null" ]; then
        echo "ERROR: plugins/$plugin.json is missing a \"repo\" field." >&2
        exit 1
    fi
}

plugin_clone_if_missing() {
    local plugin="$1" repo="$2" branch="$3"

    [ -d "$SERVERHOME/plugins/$plugin/.git" ] && return

    if ! grep -qxF "plugins/$plugin/" "$SERVERHOME/.gitignore" 2>/dev/null; then
        echo "Ignore plugin $plugin"
        echo "plugins/$plugin/" >> "$SERVERHOME/.gitignore"
    fi

    mkdir -p "$SERVERHOME/plugins/$plugin"
    cd "$SERVERHOME/plugins/$plugin"
    echo "Cloning $plugin repo into $SERVERHOME/plugins/$plugin"
    git init
    git remote add origin "$repo"
    git fetch --depth=1 origin "$branch"
    # Switch to the configured branch, force tracking, and pull down remote history
    git checkout -B "$branch" "origin/$branch"
    FOUNDPENDING=true
}

##read-only: reports uncommitted changes, or local HEAD differing from origin/<branch>.
##does a plain SHA comparison rather than an ancestry walk (git log --branches --not --remotes),
##since ancestry is unreliable on a shallow repo - see plugin_update for the same reasoning.
plugin_status() {
    local plugin="$1" branch="$2"

    if [ -n "$(git status --porcelain)" ]; then
        git status
        echo "Run plugins.sh push \"Commit message\" to commit and push changes for $plugin"
        FOUNDPENDING=true
        return
    fi

    local local_sha remote_sha
    local_sha=$(git rev-parse HEAD)
    remote_sha=$(git rev-parse "origin/$branch" 2>/dev/null)

    if [ -n "$remote_sha" ] && [ "$local_sha" != "$remote_sha" ]; then
        echo -e "\e[34mplugins/$plugin\e[0m: local HEAD differs from last-known origin/$branch (run update/pull to sync, or push if this is your own work)."
        FOUNDPENDING=true
    fi
}

##fast path: shallow fetch + reset --hard. See the usage header for the safety tradeoff.
plugin_update() {
    local plugin="$1" branch="$2"

    if [ -n "$(git status --porcelain)" ]; then
        echo -e "\e[34mplugins/$plugin has uncommitted changes, skipping update. Run: git fetch origin $branch\e[0m"
        FOUNDPENDING=true
        return
    fi

    # Fast shallow fetch for speed. Shallow history has no parent chain, so it can't reliably
    # distinguish "local is just behind" from "local has real unpushed commits" - use pull/push
    # (which unshallow) for that protection. update only guards against a dirty working tree.
    git fetch --depth=1 origin "$branch"

    local local_sha remote_sha
    local_sha=$(git rev-parse HEAD)
    remote_sha=$(git rev-parse "origin/$branch")

    if [ "$local_sha" == "$remote_sha" ]; then
        echo " plugins/$plugin is already up to date."
        return
    fi

    # In case local_sha turns out to be a real local commit (not just stale history), tag it
    # first so it stays reachable and easy to find instead of relying on reflog.
    git tag "pre-update-$(date +%Y%m%d%H%M%S)" "$local_sha" >/dev/null 2>&1
    git reset --hard "origin/$branch"
    #echo " plugins/$plugin updated to $remote_sha"
}

plugin_pull() {
    local plugin="$1" branch="$2"

    if [ -n "$(git status --porcelain)" ]; then
        echo -e "\e[34mplugins/$plugin has uncommitted changes, skipping pull. Run: git fetch origin $branch\e[0m"
        FOUNDPENDING=true
        return
    fi

    echo -e "\e[34mplugins/$plugin\e[0m: Pulling latest changes from origin/$branch"
    git fetch --depth=1 origin "$branch"

    if ! git merge --ff-only "origin/$branch"; then
        echo -e "\e[31mplugins/$plugin: Cannot fast-forward - local history has diverged from origin/$branch. Resolve manually.\e[0m"
        FOUNDPENDING=true
    fi
}

plugin_push() {
    local plugin="$1" branch="$2" commitmessage="$3"

    if [ -n "$(git status --porcelain)" ]; then
        echo -e "\e[31mplugins/$plugin has uncommitted changes:\e[0m"
        git status --short

        if [ -z "$commitmessage" ]; then
            commitmessage="Auto commit from plugins.sh"
        fi
        git add -A .
        git commit -m "$commitmessage"
        FOUNDPENDING=true
    fi

    echo -e "\e[34mplugins/$plugin\e[0m: Pulling & Pushing latest changes"
    git fetch --depth=1 origin "$branch"

    if ! git merge --ff-only "origin/$branch"; then
        echo -e "\e[31mplugins/$plugin: Cannot fast-forward - local history has diverged from origin/$branch. Push skipped, resolve manually.\e[0m"
        FOUNDPENDING=true
        return
    fi

    if ! git push origin "$branch"; then
        echo -e "\e[31mplugins/$plugin: Push failed - see error above.\e[0m"
        FOUNDPENDING=true
    fi
}

##make sure the webapp symlink is in place for any plugin that ships html/
plugin_link_webapp() {
    local plugin="$1"

    if [ -d "$SERVERHOME/plugins/$plugin/html" ] && [ ! -L "$SERVERHOME/webapp/$plugin" ]; then
        ln -nsf "$SERVERHOME/plugins/$plugin/html" "$SERVERHOME/webapp/$plugin"
    fi
}

discover_plugins

for plugin in "${plugins[@]}"; do
    cd "$SERVERHOME"
    ## remove submodule if it exists
    
    ##alwys pull if missing
    if [ ! -d "$SERVERHOME/plugins/$plugin/.git" ]; then        
        if ! grep -qxF "plugins/$plugin/" "$SERVERHOME/.gitignore" 2>/dev/null; then
            echo "Ignore plugin $plugin"
            echo "plugins/$plugin/" >> "$SERVERHOME/.gitignore"
        fi
        mkdir -p "$SERVERHOME/plugins/$plugin"
        cd "$SERVERHOME/plugins/$plugin"
        echo "Cloning $plugin repo into $SERVERHOME/plugins/$plugin"
        git init
        git remote add origin "https://github.com/entermedia-community/eme-plugin-$plugin.git"
        git fetch --depth=1 origin main
        # Switch to main, force tracking, and pull down remote history
        git checkout -B main origin/main
        FOUNDPENDING=true
    fi

   cd "$SERVERHOME/plugins/$plugin"

    if [ "$CMD" == "status" ]; then
        cd "$SERVERHOME/plugins/$plugin"
        if [ -n "$(git status --porcelain)" ]; then
            git status
            echo "Run plugins.sh push \"Commit message\" to commit and push changes for $plugin"
            FOUNDPENDING=true
            continue
        fi  
        UNPUSHED_ALL=$(git log --branches --not --remotes --oneline | wc -l)
        if [ "$UNPUSHED_ALL" -gt 0 ]; then
            echo -e "\e[34mplugins/$plugin\e[0m: You have $UNPUSHED_ALL unpushed commit(s)."
            FOUNDPENDING=true
        fi

    elif [ "$CMD" == "update" ]; then
        cd "$SERVERHOME/plugins/$plugin"
        if [ -n "$(git status --porcelain)" ]; then
            echo -e "\e[34mplugins/$plugin has uncommitted changes, skipping update. Run: git fetch origin main\e[0m"
            FOUNDPENDING=true
            continue
        fi  

        git fetch --depth=1 origin main
        # Get total unpushed commit count across all local branches
        UNPUSHED_ALL=$(git log --branches --not --remotes --oneline | wc -l)

        if [ "$UNPUSHED_ALL" -gt 0 ]; then
            echo -e "\e[34mplugins/$plugin\e[0m: You have $UNPUSHED_ALL unpushed commit(s) across your local branches."
            FOUNDPENDING=true
        else
            echo " All local branches are fully pushed."
            git reset --hard origin/main
        fi
    elif [ "$CMD" == "pull" ]; then
        cd "$SERVERHOME/plugins/$plugin"
        if [ -n "$(git status --porcelain)" ]; then
            echo -e "\e[34mplugins/$plugin has uncommitted changes, skipping pull. Run: git fetch origin main\e[0m"
            FOUNDPENDING=true
            continue
        fi  
        
        echo -e "\e[34mplugins/$plugin\e[0m: Pulling latest changes from origin/main"
        
        safe_fetch_main
        git merge --ff-only origin/main

    elif [ "$CMD" == "push" ]; then
        
        if [ -n "$(git status --porcelain)" ]; then
            ##red text for plugin with changes
            echo -e "\e[31mplugins/$plugin has uncommitted changes\e[0m"
            ##loop over list of plugins and pull them from github
            COMMITMESSAGE="$2"
            if [ -z "$COMMITMESSAGE" ]; then
                COMMITMESSAGE="Auto commit from plugins.sh"
            fi
            git add -A .
            git commit -m "$COMMITMESSAGE"
            FOUNDPENDING=true   
        fi
        echo -e "\e[34mplugins/$plugin\e[0m: Pulling & Pushing latest changes"
        safe_fetch_main
        git merge --ff-only origin/main
        git push  origin main
    fi
    cd "$SERVERHOME"
    ##make sure all the symlinks are in place for the webapp
    if [ -d "$SERVERHOME/plugins/$plugin/html" ]; then
        if [ ! -L "$SERVERHOME/webapp/$plugin" ]; then
            ln -nsf "$SERVERHOME/plugins/$plugin/html" "$SERVERHOME/webapp/$plugin"
        fi
    fi
done

if [ "$FOUNDPENDING" = true ]; then
    echo "Some plugins have pending changes. Please review the output above."
else
    echo "All plugins are up to date and have no pending changes."
fi
