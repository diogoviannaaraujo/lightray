// Launched at sign-in by a Scheduled Task, so release builds must not open a console window.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() -> anyhow::Result<()> {
    lightray_runtime::engine::host_main()
}
