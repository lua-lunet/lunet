# Benchmark Port Allocation

This document defines the port allocation scheme for benchmark testing across different framework implementations.

## Port Allocation Table

| Framework | API Port | Frontend (nginx) | Notes |
|-----------|----------|------------------|-------|
| **Lunet** | 8080     | 8081            | LuaJIT-based implementation |
| **Django** | 9090     | 9091            | Python/Django-Ninja implementation |
| **Laravel** | 7070     | 7071            | PHP/Laravel implementation |

## Usage Examples

### Django Setup
```bash
# Start Django API on port 9090
DJANGO_PORT=9090 bench/bin/bench_start_django.sh

# Start nginx proxy on port 9091 (serves frontend + proxies /api to 9090)
cd bench/django && nginx -p $(pwd) -c nginx.conf
```

### Frontend Access
- **Django Frontend**: http://localhost:9091
- **Django API Direct**: http://localhost:9090/api
- **Lunet Frontend**: http://localhost:8081 (when implemented)  
- **Lunet API Direct**: http://localhost:8080/api (when implemented)

## Directory Structure
```
bench/
├── README.md           # This file
├── django/
│   ├── nginx.conf      # Nginx config for Django (port 9091 → 9090)
│   └── conduit.html    # Single-page frontend
├── lunet/              # (Future: Lunet implementation)
└── laravel/            # (Future: Laravel implementation)
```

## Testing
Each implementation provides a complete RealWorld Conduit API with a Preact-based frontend for manual testing and benchmarking.
