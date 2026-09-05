#!/bin/bash
# Narrowly-scoped credential editor, invoked by the Cinnamon applet via
# passwordless sudo (see install-secure-sudoers.sh / install.sh's
# PIA_SET_CREDENTIAL alias).
#
# This replaces a previous NOPASSWD rule for raw `sed -i <script>
# /etc/pia-credentials`, restricted only by a sudoers glob requiring the
# script not start with '-' (`[!-]*`). That glob doesn't restrict the
# script's *content* at all: GNU sed's `e` command executes arbitrary
# shell commands, and its `w`/`r` commands write/read arbitrary files -
# e.g. `sudo sed -i '1e id > /tmp/pwned' /etc/pia-credentials` satisfies
# the pattern and grants passwordless root code execution to anything
# running as the invoking user, far beyond editing this one file.
# Sudoers argument globbing fundamentally can't safely scope a mini
# scripting language like sed, so instead of tightening the glob further,
# this script only accepts one of two hardcoded settings and validates
# the value strictly *before* it's ever substituted into a sed script -
# the actual safety boundary is this validation, not sudoers' matching.
set -euo pipefail

CREDENTIALS_FILE="/etc/pia-credentials"

usage() {
    echo "Usage: $0 region <region_id>" >&2
    echo "       $0 autoconnect <true|false>" >&2
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    echo "Error: must run as root" >&2
    exit 1
fi

if [ ! -f "$CREDENTIALS_FILE" ]; then
    echo "Error: $CREDENTIALS_FILE not found" >&2
    exit 1
fi

case "${1:-}" in
    region)
        region_id="${2:-}"
        # PIA region ids are lowercase alphanumeric plus underscores (e.g.
        # us_east, uk_london, au_sydney). This charset can't contain a
        # sed delimiter, backslash, or newline, so it's safe to
        # substitute directly into the s/// script below - there's no
        # way to break out of the substitution or inject another sed
        # command.
        if [ -z "$region_id" ] || ! [[ "$region_id" =~ ^[a-z0-9_]+$ ]]; then
            echo "Error: invalid region id '$region_id'" >&2
            exit 1
        fi
        sed -i "s/^PREFERRED_REGION=.*/PREFERRED_REGION=$region_id/" "$CREDENTIALS_FILE"
        ;;
    autoconnect)
        value="${2:-}"
        case "$value" in
            true|false)
                sed -i "s/^AUTOCONNECT=.*/AUTOCONNECT=$value/" "$CREDENTIALS_FILE"
                ;;
            *)
                echo "Error: autoconnect must be 'true' or 'false'" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        usage
        ;;
esac
