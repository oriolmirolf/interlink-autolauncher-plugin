#!/usr/bin/env bash
set -euo pipefail
PLUGIN_DIR="/opt/interlink-autolauncher-plugin"

# 1) main.py must import shlex_quote from slurm_utils
if ! grep -q "from slurm_utils import SlurmClient, shlex_quote" "$PLUGIN_DIR/main.py"; then
  sed -i 's/from slurm_utils import SlurmClient/from slurm_utils import SlurmClient, shlex_quote/' "$PLUGIN_DIR/main.py"
fi

# 2) Add sshpass support to main.py (_remote_cmd)
# If IL_SSH_USE_SSHPASS=1 and IL_SSH_PASS is set, wrap ssh/scp through sshpass and StrictHostKeyChecking=no
# Insert helper in main.py only if not present
if ! grep -q "def _sshwrap(" "$PLUGIN_DIR/main.py"; then
  awk '
    /class AutolauncherProvider/ && c==0 {print; c=1; next}
    c==1 && /def _remote_cmd/ { 
      print "    def _sshwrap(self, base):";
      print "        import os";
      print "        use = os.getenv(\"IL_SSH_USE_SSHPASS\", \"0\").lower() in (\"1\",\"true\",\"yes\")";
      print "        pw  = os.getenv(\"IL_SSH_PASS\", \"\")";
      print "        if self.s.SSH_DEST and use and pw:";
      print "            return [\"sshpass\", \"-p\", pw] + base";
      print "        return base";
      print "";
      c=2
    }
    {print}
  ' "$PLUGIN_DIR/main.py" > "$PLUGIN_DIR/main.py.tmp" && mv "$PLUGIN_DIR/main.py.tmp" "$PLUGIN_DIR/main.py"
fi

# Replace direct ssh call in _remote_cmd with wrapper
sed -i 's/return \["ssh", self.s.SSH_DEST, "bash", "-lc", joined\]/return self._sshwrap(["ssh", self.s.SSH_DEST, "bash", "-lc", joined])/' "$PLUGIN_DIR/main.py"

# 3) Do same for slurm_utils.py (_wrap)
if ! grep -q "def _sshwrap(" "$PLUGIN_DIR/slurm_utils.py"; then
  awk '
    /class SlurmClient/ && c==0 {print; c=1; next}
    c==1 && /def _wrap/ { 
      print "    def _sshwrap(self, base):";
      print "        import os";
      print "        use = os.getenv(\"IL_SSH_USE_SSHPASS\", \"0\").lower() in (\"1\",\"true\",\"yes\")";
      print "        pw  = os.getenv(\"IL_SSH_PASS\", \"\")";
      print "        if self.s.SSH_DEST and use and pw:";
      print "            return [\"sshpass\", \"-p\", pw] + base";
      print "        return base";
      print "";
      c=2
    }
    {print}
  ' "$PLUGIN_DIR/slurm_utils.py" > "$PLUGIN_DIR/slurm_utils.py.tmp" && mv "$PLUGIN_DIR/slurm_utils.py.tmp" "$PLUGIN_DIR/slurm_utils.py"
fi

sed -i 's/return \["ssh", self.s.SSH_DEST, "bash", "-lc", joined\]/return self._sshwrap(["ssh", self.s.SSH_DEST, "bash", "-lc", joined])/' "$PLUGIN_DIR/slurm_utils.py"

echo "Patched plugin for sshpass + fixed import."
