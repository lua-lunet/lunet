# Agent Notes: Benchmark Environment

This directory contains benchmark configurations for comparing Lunet against other RealWorld Conduit implementations.

## Port Allocation

| Framework | API Port | Nginx Port |
|-----------|----------|------------|
| Lunet     | 8080     | 8081       |
| Django    | 9090     | 9091       |
| Laravel   | 7070     | 7071       |

## PostgreSQL Setup (Django/Laravel)

PostgreSQL is used for Django and Laravel benchmarks. It runs locally on macOS (not in a VM).

### Quick Reference

**Start PostgreSQL (manual - do NOT auto-start):**
```bash
brew services start postgresql
```

**Stop when done:**
```bash
brew services stop postgresql
```

**Create database (one-time):**
```bash
createdb conduit
```

**Verify connection:**
```bash
psql -h 127.0.0.1 -U $(whoami) -c "SELECT 1" conduit
```

### Connection Details
- Host: `127.0.0.1`
- Port: `5432`
- Database: `conduit`
- User: Your macOS username (no password for local peer auth)

## Django Setup

### Requirements
- **Python 3.12** via mise (Python 3.14 has compatibility issues with Django dependencies)
- PostgreSQL running with `conduit` database

### mise Python Setup
```bash
# Initialize benchmark environment (installs/configures Python 3.12 via mise)
make init-bench

# Verify
eval "$(mise activate bash)" && python3 --version
# Should show: Python 3.12.x
```

### Setup Scripts
- `bin/bench_setup_django.lua` - Clones repo, creates venv, installs deps, runs migrations
- `bin/bench_start_django.sh` - Starts Django + nginx
- `bin/bench_stop_django.sh` - Stops both services

### Manual Setup
```bash
# 1. Initialize environment
make init-bench

# 2. Run setup
lua bin/bench_setup_django.lua

# 3. Start services
./bin/bench_start_django.sh

# 4. Access
# Frontend: http://localhost:9091
# API: http://localhost:9090/api
```

### Django App Location
The Django app is cloned to `.tmp/bench/django/` (gitignored). 

Source repo: `simbo1905/realWorld-DjangoRestFramework` (fork with fixes):
- JWT token returned on registration (upstream bug fix)
- Database config uses environment variables with sensible defaults

### Database Config
Django settings (`config/settings.py`) use environment variables:
```python
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('DATABASE_NAME', 'conduit'),
        'USER': os.getenv('DATABASE_USER', os.getenv('USER', 'postgres')),
        'PASSWORD': os.getenv('DATABASE_PASSWORD', ''),
        'HOST': os.getenv('DATABASE_HOST', '127.0.0.1'),
        'PORT': '5432'
    }
}
```

Defaults work out-of-the-box on macOS with local PostgreSQL.

### Troubleshooting

**`pkg_resources` not found:**
```bash
.tmp/bench/django/venv/bin/pip install setuptools
```

**psycopg2 build fails:**
Ensure using Python 3.12 via mise, not system Python 3.14.

**Connection refused:**
```bash
brew services start postgresql
```

## Directory Structure

```
bench/
  django/
    nginx.conf      # Nginx config for port 9091
    conduit.html    # Preact frontend (CDN-based, no build)
  AGENTS.md         # This file

.tmp/bench/
  django/           # Cloned Django app (gitignored)
    venv/           # Python virtual environment
    manage.py
    ...
```
