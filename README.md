# BFS CDP Inventory

**Usage**
1. Place `Hosts.txt` in the same folder as `executor.ps1` (one hostname/IP per line).
2. Ensure SecureCRT is installed at `C:\Program Files\VanDyke Software\SecureCRT\SecureCRT.exe` or pass `-SecureCrt` with your path.
3. Run:
   ```powershell
   powershell -NoProfile -File .\executor.ps1
   ```

You will be prompted for credentials via a GUI popup.

**Outputs (created in the current folder)**
- `cdp_output\cdp\*.txt` raw `show cdp neighbors`
- `cdp_output\inventory\*.txt` raw `show inventory`
- `cdp_edges.csv` (source,neighbor)
- `inventory.csv` (device, platform, chassis, serial, pid, descr)
- `found_hosts.txt` running unique host list
- `hosts_next.txt` next-level queue

**Notes**
- Optional args: `-HostsFile`, `-OutputDir`, `-EdgesFile`, `-InventoryFile`, `-MaxDepth`, `-TimeoutSec`, `-SecureCrt`, `-ScriptPath`.
