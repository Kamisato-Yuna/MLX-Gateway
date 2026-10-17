"""Run the real supervisor with extra fixture diagnostics, without changing behavior."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "script"))
import whisper_supervisor as service

original_loaded = service.Supervisor.loaded


def loaded(self):
    try:
        return original_loaded(self)
    except Exception as error:
        try:
            listeners = sorted(service.listener_pids(self.config.base_url))
        except Exception as inspection_error:
            listeners = str(inspection_error)
        detail = (str(error), listeners)
        if getattr(self, "fixture_last_probe", None) != detail:
            service.event("fixture_probe", error=str(error), listeners=listeners,
                          child=self.child.pid if self.child else None)
            self.fixture_last_probe = detail
        raise


service.Supervisor.loaded = loaded
raise SystemExit(service.main())
