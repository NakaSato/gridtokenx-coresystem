#!/bin/bash
# GridTokenX - Seed command (database)

cmd_seed() {
    show_banner
    log_info "Seeding database with test users..."

    if [ -f "$PROJECT_ROOT/scripts/seed_1000_users.sql" ]; then
        docker exec -i gridtokenx-postgres psql -U gridtokenx_user -d gridtokenx < "$PROJECT_ROOT/scripts/seed_1000_users.sql"
        log_success "Database seeded with test users!"
    else
        log_warn "seed_1000_users.sql not found, skipping"
    fi
}
