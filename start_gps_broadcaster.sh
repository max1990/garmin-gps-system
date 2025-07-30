#!/bin/bash

# Legacy startup script - redirects to new service
# This maintains compatibility with old references

echo "[LEGACY] Redirecting to new service implementation..."
exec /home/cuas/run_gps_service.sh
