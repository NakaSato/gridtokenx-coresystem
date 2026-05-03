#!/usr/bin/env nu
# GridTokenX Development Helper Script (Nushell)

const PROJECT_ROOT = "/Users/chanthawat/Developments/gridtokenx-coresystem"

# --- Core Commands ---

def "grx check" [] {
    print "🔍 Checking all microservices..."
    cd $PROJECT_ROOT
    just check-all
}

def "grx build" [] {
    print "🔨 Building all binaries..."
    cd $PROJECT_ROOT
    just build-all
}

def "grx test" [] {
    print "🧪 Running all tests..."
    cd $PROJECT_ROOT
    just test
}

def "grx migrate" [] {
    print "🗄️ Running database migrations..."
    cd $PROJECT_ROOT
    just migrate
    just noti-migrate
}

def "grx noti-migrate" [] {
    print "🗄️ Running Noti Service database migrations..."
    cd $PROJECT_ROOT
    just noti-migrate
}

# --- Infrastructure Commands ---

def "grx db-up" [] {
    print "🐳 Starting PostgreSQL..."
    cd $PROJECT_ROOT
    just db-up
}

def "grx db-down" [] {
    print "🛑 Stopping PostgreSQL..."
    cd $PROJECT_ROOT
    just db-down
}

def "grx orb-up" [] {
    print "🌩️ Starting all OrbStack services..."
    cd $PROJECT_ROOT
    just orb-up
}

def "grx orb-down" [] {
    print "🛑 Stopping all OrbStack services..."
    cd $PROJECT_ROOT
    just orb-down
}

# --- Execution Commands ---

def "grx run-native" [] {
    print "🚀 Starting all services natively (background)..."
    cd $PROJECT_ROOT
    bash ./scripts/app.sh start --native-apps
}

def "grx stop" [] {
    print "🛑 Stopping all services..."
    cd $PROJECT_ROOT
    bash ./scripts/app.sh stop
}

def "grx status" [] {
    cd $PROJECT_ROOT
    bash ./scripts/app.sh status
}

def "grx verify-reg" [] {
    print "🏆 Verifying Registration E2E Flow..."
    cd $PROJECT_ROOT
    bash ./scripts/test-registration-e2e.sh
}

# --- Main Entry Point ---

def main [cmd?: string] {
    match $cmd {
        "check" => { grx check }
        "build" => { grx build }
        "test" => { grx test }
        "migrate" => { grx migrate }
        "noti-migrate" => { grx noti-migrate }
        "db-up" => { grx db-up }
        "db-down" => { grx db-down }
        "orb-up" => { grx orb-up }
        "orb-down" => { grx orb-down }
        "run-native" => { grx run-native }
        "stop" => { grx stop }
        "status" => { grx status }
        "verify-reg" => { grx verify-reg }
        _ => {
            print "Usage: grx <command>"
            print ""
            print "Commands:"
            print "  check         - Run cargo check on all services"
            print "  build         - Build all binaries"
            print "  test          - Run all tests"
            print "  migrate       - Run all database migrations (IAM + Noti)"
            print "  noti-migrate  - Run only Notification Service migrations"
            print "  db-up         - Start PostgreSQL (OrbStack)"
            print "  db-down       - Stop PostgreSQL"
            print "  orb-up        - Start all OrbStack services"
            print "  orb-down      - Stop all OrbStack services"
            print "  run-native    - Start services natively (background)"
            print "  stop          - Stop all services"
            print "  status        - Check service status"
            print "  verify-reg    - Run Registration E2E verification"
        }
    }
}
