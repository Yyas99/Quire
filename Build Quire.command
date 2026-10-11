#!/bin/bash
# Double-click in Finder to compile Quire and open it. Output is saved to build.log.
cd "$(dirname "$0")" && chmod +x quire && ./quire build
echo
echo "You can close this window."
