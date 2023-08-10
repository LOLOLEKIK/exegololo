#!/bin/bash
# SIGTERM received (the container is stopping, every process must be gracefully stopped before the timeout).
trap shutdown SIGTERM

function exegol_init() {
    usermod -s "/.exegol/start.sh" root
}

# Function specific
function load_setups() {
  # Load custom setups (supported setups, and user setup)
  [ -d /var/log/exegol ] || mkdir -p /var/log/exegol
  if [[ ! -f /.exegol/.setup.lock ]]; then
    # Execute initial setup if lock file doesn't exist
    echo >/.exegol/.setup.lock
    # Run my-resources script. Logs starting with '[exegol]' will be print to the console and report back to the user through the wrapper.
    if [ -f /.exegol/load_supported_setups.sh ]; then
      echo "Installing [green]my-resources[/green] custom setup ..."
      /.exegol/load_supported_setups.sh |& tee /var/log/exegol/load_setups.log | grep -i '^\[exegol]' | sed "s/^\[exegol\]\s*//gi"
      [ -f /var/log/exegol/load_setups.log ] && echo "Compressing [green]my-resources[/green] logs" && gzip /var/log/exegol/load_setups.log && echo "My-resources loaded"
    else
      echo "[W]Your exegol image doesn't support my-resources custom setup!"
    fi
  fi
}

function finish() {
    echo "READY"
}

function endless() {
  # Start action / endless
  finish
  # Entrypoint for the container, in order to have a process hanging, to keep the container alive
  # Alternative to running bash/zsh/whatever as entrypoint, which is longer to start and to stop and to very clean
  # shellcheck disable=SC2162
  read -u 2  # read from stderr => endlessly wait effortlessly
}

function shutdown() {
  # Shutting down the container.
  # Sending SIGTERM to all interactive process for proper closing
  pgrep vnc && desktop-stop  # Stop webui desktop if started TODO improve desktop shutdown
  # shellcheck disable=SC2046
  kill $(pgrep -f -- openvpn | grep -vE '^1$') 2>/dev/null
  # shellcheck disable=SC2046
  kill $(pgrep -x -f -- zsh) 2>/dev/null
  # shellcheck disable=SC2046
  kill $(pgrep -x -f -- -zsh) 2>/dev/null
  # shellcheck disable=SC2046
  kill $(pgrep -x -f -- bash) 2>/dev/null
  # shellcheck disable=SC2046
  kill $(pgrep -x -f -- -bash) 2>/dev/null
  # Wait for every active process to exit (e.g: shell logging compression, VPN closing, WebUI)
  wait_list="$(pgrep -f "(.log|start.sh|vnc)" | grep -vE '^1$')"
  for i in $wait_list; do
    # Waiting for: $i PID process to exit
    tail --pid="$i" -f /dev/null
  done
  exit 0
}

function _resolv_docker_host() {
  # On docker desktop host, resolving the host.docker.internal before starting a VPN connection for GUI applications
  docker_ip=$(getent hosts host.docker.internal | head -n1 | awk '{ print $1 }')
  if [ "$docker_ip" ]; then
    # Add docker internal host resolution to the hosts file to preserve access to the X server
    echo "$docker_ip        host.docker.internal" >>/etc/hosts
  fi
}

function ovpn() {
  [[ "$DISPLAY" == *"host.docker.internal"* ]] && _resolv_docker_host
  if ! command -v openvpn &> /dev/null
  then
      echo '[E]Your exegol image is not up-to-date! VPN feature is not supported!'
  else
    # Starting openvpn as a job with '&' to be able to receive SIGTERM signal and close everything properly
    echo "Starting [green]VPN[/green]"
    openvpn --log-append /var/log/exegol/vpn.log "$@" &
    sleep 2  # Waiting 2 seconds for the VPN to start before continuing
  fi

}

function run_cmd() {
  /bin/zsh -c "autoload -Uz compinit; compinit; source ~/.zshrc; eval \"$CMD\""
}

function desktop() {
  if command -v desktop-start &> /dev/null
  then
      echo "Starting Exegol [green]desktop[/green] with [blue]${DESKTOP_PROTO}[/blue]"
      desktop-start &>> ~/.vnc/startup.log  # Disable logging
      sleep 2  # Waiting 2 seconds for the Desktop to start before continuing
  else
      echo '[E]Your exegol image is not up-to-date! Desktop feature is not supported!'
  fi
}

##### How "echo" works here with exegol #####
#
# Every message printed here will be displayed to the console logs of the container
# The container logs will be displayed by the wrapper to the user at startup through a progress animation (and a verbose line if -v is set)
# The logs written to ~/banner.txt will be printed to the user through the .zshrc file on each new session (until the file is removed).
# Using 'tee -a' after a command will save the output to a file AND to the console logs.
#
#############################################
echo "Starting exegol"
exegol_init

### Argument parsing

# Par each parameter
for arg in "$@"; do
 # Check if the function exist
 function_name=$(echo "$arg" | cut -d ' ' -f 1)
 if declare -f "$function_name" > /dev/null; then
   $arg
 else
   echo "The function '$arg' doesn't exist."
 fi
done
