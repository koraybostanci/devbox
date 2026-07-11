#!/bin/bash

doctor_check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'PASS: %s\n' "$description"
    else
        printf 'FAIL: %s\n' "$description" >&2
        DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
    fi
}

run_doctor() {
    local state guest_failures guest_output
    DOCTOR_FAILURES=0

    doctor_check "macOS host" test "$(uname -s)" = Darwin
    doctor_check "Apple Silicon host" test "$(uname -m)" = arm64
    doctor_check "Colima is installed" command -v colima
    doctor_check "Docker CLI is installed" command -v docker
    doctor_check "Docker Compose is installed" docker compose version
    doctor_check "jq is installed" command -v jq
    doctor_check "yq is installed" command -v yq
    doctor_check "OpenSSH client is installed" command -v ssh

    if [ -f "$DEVBOX_DIR/.env" ]; then
        doctor_check ".env permissions are 0600" test "$(file_mode "$DEVBOX_DIR/.env")" = 600
    else
        printf 'FAIL: %s\n' ".env exists" >&2
        DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
    fi

    state="$(colima_state)"
    printf 'INFO: isolated VM state: %s\n' "${state:-Not created}"
    if [ "$state" = "Running" ]; then
        doctor_check "Colima SSH is reachable" guest_exec true
        doctor_check "managed SSH host is reachable" ssh -o BatchMode=yes -o ConnectTimeout=10 devbox true
        if guest_exec test -f /provision/scripts/verify.sh >/dev/null 2>&1; then
            printf 'PASS: %s\n' "guest verifier is available"
            guest_output="$(guest_exec bash -c '
                set +e
                bash /provision/scripts/verify.sh
                verify_status=$?
                printf "DEVBOX_VERIFY_FAILURES=%s\n" "$verify_status"
                exit 0
            ' 2>&1)"
            guest_failures="$(printf '%s\n' "$guest_output" | awk -F= '/^DEVBOX_VERIFY_FAILURES=/{print $2}')"
            [[ "$guest_failures" =~ ^[0-9]+$ ]] || guest_failures=1
            printf '%s\n' "$guest_output" | awk '!/^DEVBOX_VERIFY_FAILURES=/'
            DOCTOR_FAILURES=$((DOCTOR_FAILURES + guest_failures))
        else
            printf 'FAIL: %s\n' "guest verifier is available" >&2
            DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
        fi
    fi

    if ((DOCTOR_FAILURES > 0)); then
        die "$DOCTOR_FAILURES doctor check(s) failed"
    fi
    log "All doctor checks passed."
}
