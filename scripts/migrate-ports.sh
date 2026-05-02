#!/usr/bin/env bash
# ============================================================================
# GridTokenX Port Numbering Migration Script
# ============================================================================
# Migrates all port assignments from scattered/random values to the structured
# range-based numbering scheme for distributed systems.
#
# Usage: ./scripts/migrate-ports.sh [--dry-run] [--force]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/.port-backup-$(date +%Y%m%d_%H%M%S)"
DRY_RUN=false
FORCE=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force)   FORCE=true; shift ;;
        *)         log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if $DRY_RUN; then
    log_warn "DRY RUN MODE — No files will be modified"
fi

# Port mapping: old → new
# Format: "old_port:new_port"
MAPPINGS=(
    # Persistence
    "5434:7001" "5433:7002"
    "6379:7010" "6380:7011"
    "8086:7020" "8123:7030" "9000:7031"
    # User-facing
    "8080:4010" "8081:4010" "8093:4020"
    "4010:4030" "3001:6002"
    # gRPC
    "50051:5030" "50052:5010" "50053:5020"
    "8090:5010" "8091:5020" "8092:5020" "8095:5040"
    # Messaging
    "9092:9001" "9094:9002" "9096:9003"
    "15672:9031" "5672:9030"
    # Observability
    "9090:6001" "3100:6003" "3200:6004" "4317:6006"
    # Infrastructure
    "8200:13001"
)

# ============================================================================
# Backup
# ============================================================================
create_backup() {
    $DRY_RUN && return
    log_info "Creating backup: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    find "$PROJECT_ROOT" -type f \( \
        -name "*.env*" -o -name "*.yml" -o -name "*.yaml" -o \
        -name "*.rs" -o -name "*.md" -o -name "*.sh" -o \
        -name "*.py" -o -name "*.toml" -o -name "*.conf" -o \
        -name "Dockerfile*" -o -name "*.cpp" -o -name "*.ts" -o \
        -name "*.tsx" -o -name "*.js" \
    \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/.port-backup-*" -not -path "*/uv.lock" -not -path "*/cache/*" \
    -exec grep -l "5434\|6379\|8080\|8090\|8092\|8093\|8095\|50051\|50052\|50053\|8086\|9092\|9094\|9096\|3001\|9090\|8200\|15672" {} + 2>/dev/null | while read -r file; do
        rel="${file#$PROJECT_ROOT/}"
        mkdir -p "$(dirname "$BACKUP_DIR/$rel")"
        cp "$file" "$BACKUP_DIR/$rel"
    done
    log_success "Backup saved: $BACKUP_DIR"
}

# ============================================================================
# Dry Run
# ============================================================================
show_changes() {
    $DRY_RUN || return
    log_info "Scanning for old port references..."
    echo ""
    find "$PROJECT_ROOT" -type f \( \
        -name "*.env*" -o -name "*.yml" -o -name "*.yaml" -o \
        -name "*.rs" -o -name "*.md" -o -name "*.sh" -o \
        -name "*.py" -o -name "*.toml" -o -name "*.conf" -o \
        -name "Dockerfile*" -o -name "*.cpp" -o -name "*.ts" -o \
        -name "*.tsx" -o -name "*.js" \
    \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/.port-backup-*" -not -path "*/uv.lock" -not -path "*/cache/*" 2>/dev/null | while read -r file; do
        rel="${file#$PROJECT_ROOT/}"
        for mapping in "${MAPPINGS[@]}"; do
            old="${mapping%%:*}"
            new="${mapping##*:}"
            count=$(grep -c ":${old}\b" "$file" 2>/dev/null || true)
            if [[ "$count" -gt 0 ]]; then
                echo -e "  $rel: ${RED}:$old${NC} → ${GREEN}:$new${NC} ($count)"
            fi
        done
    done
}

# ============================================================================
# Apply Migration
# ============================================================================
apply_migration() {
    $DRY_RUN && return
    log_info "Applying port migrations..."
    CHANGES=0

    find "$PROJECT_ROOT" -type f \( \
        -name "*.env*" -o -name "*.yml" -o -name "*.yaml" -o \
        -name "*.rs" -o -name "*.md" -o -name "*.sh" -o \
        -name "*.py" -o -name "*.toml" -o -name "*.conf" -o \
        -name "Dockerfile*" -o -name "*.cpp" -o -name "*.ts" -o \
        -name "*.tsx" -o -name "*.js" \
    \) -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/.port-backup-*" -not -path "*/uv.lock" -not -path "*/cache/*" 2>/dev/null | while read -r file; do
        rel="${file#$PROJECT_ROOT/}"
        for mapping in "${MAPPINGS[@]}"; do
            old="${mapping%%:*}"
            new="${mapping##*:}"
            if grep -q ":${old}\b" "$file" 2>/dev/null; then
                sed -i '' "s/:${old}\b/:${new}/g" "$file"
                log_info "  $rel: :$old → :$new"
                CHANGES=$((CHANGES + 1))
            fi
        done
    done
    log_success "Migration complete"
}

# ============================================================================
# Verify
# ============================================================================
verify_migration() {
    log_info "Verifying..."
    for port in 7001 7010 4010 4030 5030 5010 5020 5040 9001 6002 6001; do
        if grep -rq ":${port}\b" "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/docker-compose.yml" 2>/dev/null; then
            log_success "  :$port found"
        else
            log_warn "  :$port not found — manual review needed"
        fi
    done
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  GridTokenX Port Migration Tool${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    if $DRY_RUN; then
        show_changes
    else
        if ! $FORCE; then
            log_warn "This will modify port configurations across the project."
            read -rp "Create backup and proceed? [y/N] " confirm
            [[ "$confirm" =~ ^[Yy] ]] || { log_info "Aborted."; exit 0; }
        fi
        create_backup
        apply_migration
        verify_migration
    fi

    echo ""
    echo -e "${BLUE}========================================${NC}"
    if $DRY_RUN; then
        log_warn "DRY RUN — Run without --dry-run to apply"
    else
        log_success "Migration applied"
        echo "  Backup: $BACKUP_DIR"
        echo "  Rollback: ./scripts/rollback-ports.sh"
    fi
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Port Scheme:"
    echo "  4000  User APIs    5000  gRPC       6000  Observability"
    echo "  7000  Persistence  8000  Blockchain 9000  Messaging"
    echo "  10000 Admin        11000 Frontend   12000 Edge IoT"
    echo "  13000 Infrastructure"
    echo ""
}

main "$@"
