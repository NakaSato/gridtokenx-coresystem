#!/bin/bash
# GridTokenX - Register command (admin user)

cmd_register() {
    show_banner

    local email="${1:-admin_$(date +%s)@example.com}"
    local username="${2:-admin_$(date +%s)}"
    local password="${3:-P@ssw0rd123!}"
    local first_name="${4:-Admin}"
    local last_name="${5:-User}"

    log_info "Registering admin user..."
    echo "  Email: $email"
    echo "  Username: $username"
    if [ -t 1 ]; then
        echo "  Password: $password"
    else
        echo "  Password: [HIDDEN IN NON-INTERACTIVE MODE]"
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
    fi

    local resp=$(curl -s -X POST "$API_URL/api/v1/auth/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"email\": \"$email\",
            \"password\": \"$password\",
            \"username\": \"$username\",
            \"first_name\": \"$first_name\",
            \"last_name\": \"$last_name\"
        }")

    local token=$(echo "$resp" | jq -r '.data.auth.access_token // .auth.access_token // empty')
    
    # Auto-verify the user (shortcut for dev)
    log_info "Verifying email for activation..."
    curl -s -X GET "$API_URL/api/v1/auth/verify?token=verify_$email" > /dev/null

    if [ -z "$token" ] || [ "$token" == "null" ]; then
        log_info "Registration successful, waiting for service to sync..."
        sleep 1
        log_info "Attempting automatic login to get token..."
        resp=$(curl -s -X POST "$API_URL/api/v1/auth/login" \
            -H "Content-Type: application/json" \
            -d "{
                \"username\": \"$username\",
                \"password\": \"$password\"
            }")
        token=$(echo "$resp" | jq -r '.access_token // .data.auth.access_token // .auth.access_token // empty')
    fi

    if [ -n "$token" ] && [ "$token" != "null" ]; then
        echo "$token" > "$PROJECT_ROOT/.admin_token"
        log_success "Admin registered and authenticated successfully!"
        log_info "Token saved to .admin_token"
    else
        log_error "Failed to acquire admin token. Response: $resp"
    fi
}
