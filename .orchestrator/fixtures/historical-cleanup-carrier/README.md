# Historical cleanup carrier

Original raw source from commit `f85f146380fb82dcee44accba762032f51987bf4`,
path `.orchestrator/admission-temp-cleanup.test.ps1`. No private Git history
is archived. The filename below avoids battery discovery of the historical
test; its bytes are unchanged. The ordinary current test extracts only the
original `Stop-Exact` definition and adds its existing observation barrier.
No original or current cleanup assertion, process control or wait is replaced.

- .orchestrator/admission-temp-cleanup-before.ps1 | blob `611c05666a74e39444cbf84e3e0ff2369d94a27b`
