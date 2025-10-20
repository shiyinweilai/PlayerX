#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

use std::process::Command;
use tauri::Manager;

#[tauri::command]
fn run_executable(arg1: String, arg2: String) -> Result<String, String> {
    // 假设你可执行文件名为 video-compare，放在src-tauri/bin目录
    // 你可以打包进resources，启动时用绝对路径

    // 这里简单用相对路径示例，生产中请用绝对路径管理
    let exe_path = "./src-tauri/bin/video-compare";

    let output = Command::new(exe_path)
        .arg(arg1)
        .arg(arg2)
        .output()
        .map_err(|e| format!("启动失败：{}", e))?;
    
    if output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        Ok(stdout.into())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(stderr.into())
    }
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![run_executable])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}