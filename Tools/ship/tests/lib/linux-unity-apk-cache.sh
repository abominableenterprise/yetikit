# Shared synthetic cache command and keys for the APK cache workers.
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/linux-unity-apk-fixture.sh"
apk_module

cat > "$tmp/bin/fake-cache" <<EOF
#!/bin/sh
echo "\$1 \$2" >> "$tmp/cache-calls"
case "\$1" in restore) if [ "\$2" = "\${FAKE_HIT:-}" ]; then mkdir -p Library/hit; [ "\${FAKE_WARM_RESTORE:-0}" = 0 ] || mkdir -p Library/Bee/Android; exit 0; fi
  if [ "\${FAKE_PARTIAL:-0}" = 1 ]; then mkdir -p Library .task-cache.partial; : > Library/partial; fi; exit 3 ;; esac
[ "\$1" = save ] && { [ -e Library/Bee ] || echo "\$1 \$2 nobee" >> "$tmp/cache-bee"; exit "\${FAKE_SAVE_RC:-0}"; }
EOF
chmod +x "$tmp/bin/fake-cache"
k="$(bash "$script" cache-key)"; ka="$(bash "$script" cache-key android)"
