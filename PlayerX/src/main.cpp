/**
 * main.cpp — PlayerX 入口
 */
#include "ui/rb_player_ui.h"
#include "utils/rb_utils.h"
#include <iostream>

int main(int argc, char* argv[]) {
    rb::RBPlayerUI ui;

    if (!ui.rbInit("PlayerX", 1280, 720)) {
        std::cerr << "[PlayerX] 初始化失败，退出" << std::endl;
        return 1;
    }

    // 命令行参数：直接传入视频文件路径（最多 4 个）
    for (int i = 1; i < argc && i <= 4; ++i) {
        // 根据文件数量自动切换布局
        if (i == 2) ui.rbSetLayout(rb::RBLayoutMode::Dual);
        else if (i == 3) ui.rbSetLayout(rb::RBLayoutMode::Triple);
        else if (i == 4) ui.rbSetLayout(rb::RBLayoutMode::Quad);
        ui.rbOpenFileForCell(i - 1, argv[i]);
    }

    ui.rbRunLoop();

    // 退出前清理可能残留的文件对话框子进程，避免 osascript 窗口脱离主程序后仍显示
    rb::rbShutdownFileDialog();
    return 0;
}
