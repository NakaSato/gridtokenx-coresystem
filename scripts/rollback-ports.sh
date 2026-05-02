#!/usr/bin/env bash
# ============================================================================
# GridTokenX Port Numbering Rollback Script
# ============================================================================
# Restores port assignments from backup created by migrate-ports.sh.
#
# Usage: ./scripts/rollback-ports.sh [--backup-dir <path>] [--force]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR=""
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
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --force)      FORCE=true; shift ;;
        *)            log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Find latest backup
if [[ -z "$BACKUP_DIR" ]]; then
    BACKUP_DIR=$(find "$PROJECT_ROOT" -maxdepth 1 -type d -name ".port-backup-*" 2>/dev/null | sort | tail -n 1)
    if [[ -z "$BACKUP_DIR" ]]; then
        log_error "No backup found. Run ./scripts/migrate-ports.sh first."
        exit 1
    fi
    log_info "Using latest backup: $BACKUP_DIR"
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
    log_error "Backup not found: $BACKUP_DIR"
    exit 1
fi

# Confirm
if ! $FORCE; then
    log_warn "This will RESTORE all files from backup, reverting port changes."
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy] ]] || { log_info "Aborted."; exit 0; }
fi

# Restore
log_info "Rolling back from: $BACKUP_DIR"
RESTORED=0

find "$BACKUP_DIR" -type f -not -name ".*" 2>/dev/null | while read -r backup_file; do
    rel="${backup_file#$BACKUP_DIR/}"
    dest="$PROJECT_ROOT/$rel"
    mkdir -p "$(dirname "$dest")"
    cp "$backup_file" "$dest"
    log_info "  Restored: $rel"
done

log_success "Rollback complete"
echo ""
echo "Next steps:"
echo "  1. git diff  (review changes)"
echo "  2. ./scripts/app.sh restart"
echo ""
echo "Additional backups:"
find "$PROJECT_ROOT" -maxdepth 1 -type d -name ".port-backup-*" 2>/dev/null | sort
