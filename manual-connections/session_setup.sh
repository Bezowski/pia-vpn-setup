# session_setup.sh
#!/bin/bash

# Activate existing D-Bus session and export necessary variables
export $(dbus-launch)
export DISPLAY=:0
