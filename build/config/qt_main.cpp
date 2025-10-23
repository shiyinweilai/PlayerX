#include <QApplication>
#include <QMainWindow>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QLineEdit>
#include <QLabel>
#include <QFileDialog>
#include <QMessageBox>
#include <QProcess>
#include <QWidget>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QCoreApplication>
#include <iostream>
#include <string>

class VideoCompareUI : public QMainWindow
{
    Q_OBJECT

public:
    VideoCompareUI(QWidget *parent = nullptr) : QMainWindow(parent)
    {
        setWindowTitle("Video Compare - QT UI");
        setMinimumSize(600, 200);
        
        // 创建中央部件
        QWidget *centralWidget = new QWidget(this);
        setCentralWidget(centralWidget);
        
        // 创建布局
        QVBoxLayout *mainLayout = new QVBoxLayout(centralWidget);
        
        // 左侧视频文件选择
        QHBoxLayout *leftLayout = new QHBoxLayout();
        QLabel *leftLabel = new QLabel("左侧视频文件:");
        leftFileEdit = new QLineEdit();
        leftFileEdit->setPlaceholderText("选择左侧视频文件...");
        QPushButton *leftBrowseBtn = new QPushButton("浏览...");
        
        leftLayout->addWidget(leftLabel);
        leftLayout->addWidget(leftFileEdit);
        leftLayout->addWidget(leftBrowseBtn);
        
        // 右侧视频文件选择
        QHBoxLayout *rightLayout = new QHBoxLayout();
        QLabel *rightLabel = new QLabel("右侧视频文件:");
        rightFileEdit = new QLineEdit();
        rightFileEdit->setPlaceholderText("选择右侧视频文件...");
        QPushButton *rightBrowseBtn = new QPushButton("浏览...");
        
        rightLayout->addWidget(rightLabel);
        rightLayout->addWidget(rightFileEdit);
        rightLayout->addWidget(rightBrowseBtn);
        
        // 启动按钮
        QPushButton *startBtn = new QPushButton("启动视频对比");
        startBtn->setStyleSheet("QPushButton { background-color: #4CAF50; color: white; font-weight: bold; padding: 10px; }");
        
        // 添加到主布局
        mainLayout->addLayout(leftLayout);
        mainLayout->addLayout(rightLayout);
        mainLayout->addWidget(startBtn);
        
        // 连接信号和槽
        connect(leftBrowseBtn, &QPushButton::clicked, this, &VideoCompareUI::browseLeftFile);
        connect(rightBrowseBtn, &QPushButton::clicked, this, &VideoCompareUI::browseRightFile);
        connect(startBtn, &QPushButton::clicked, this, &VideoCompareUI::startComparison);
    }

private slots:
    void browseLeftFile()
    {
        QString filePath = QFileDialog::getOpenFileName(this, "选择左侧视频文件", QDir::homePath(), 
                                                       "视频文件 (*.mp4 *.avi *.mkv *.mov *.wmv *.flv *.webm);;所有文件 (*.*)");
        if (!filePath.isEmpty()) {
            leftFileEdit->setText(filePath);
        }
    }
    
    void browseRightFile()
    {
        QString filePath = QFileDialog::getOpenFileName(this, "选择右侧视频文件", QDir::homePath(), 
                                                       "视频文件 (*.mp4 *.avi *.mkv *.mov *.wmv *.flv *.webm);;所有文件 (*.*)");
        if (!filePath.isEmpty()) {
            rightFileEdit->setText(filePath);
        }
    }
    
    void startComparison()
    {
        QString leftFile = leftFileEdit->text();
        QString rightFile = rightFileEdit->text();
        
        if (leftFile.isEmpty() || rightFile.isEmpty()) {
            QMessageBox::warning(this, "错误", "请选择两个视频文件");
            return;
        }
        
        if (!QFile::exists(leftFile)) {
            QMessageBox::warning(this, "错误", "左侧视频文件不存在");
            return;
        }
        
        if (!QFile::exists(rightFile)) {
            QMessageBox::warning(this, "错误", "右侧视频文件不存在");
            return;
        }
        
        // 获取当前可执行文件路径（假设QT版本和命令行版本在同一目录）
        QString currentExePath = QCoreApplication::applicationFilePath();
        QFileInfo exeInfo(currentExePath);
        QString exeDir = exeInfo.absolutePath();
        QString cmdExePath = exeDir + "/video-compare";
        
        // 在macOS上，如果是在app bundle中，需要调整路径
        #ifdef Q_OS_MAC
        if (currentExePath.contains(".app")) {
            // 在app bundle中，命令行版本应该在Resources目录的同级目录
            QDir appDir = exeInfo.dir();
            appDir.cdUp(); // Contents
            appDir.cdUp(); // .app
            appDir.cdUp(); // 上级目录
            cmdExePath = appDir.absolutePath() + "/video-compare";
        }
        #endif
        
        if (!QFile::exists(cmdExePath)) {
            QMessageBox::warning(this, "错误", "找不到命令行版本的可执行文件: " + cmdExePath);
            return;
        }
        
        // 启动命令行版本
        QProcess *process = new QProcess(this);
        QStringList arguments;
        arguments << leftFile << rightFile;
        
        process->start(cmdExePath, arguments);
        
        if (!process->waitForStarted()) {
            QMessageBox::warning(this, "错误", "无法启动视频对比程序");
            return;
        }
        
        QMessageBox::information(this, "成功", "视频对比程序已启动");
        
        // 可选：关闭UI窗口
        // this->close();
    }

private:
    QLineEdit *leftFileEdit;
    QLineEdit *rightFileEdit;
};

#include "qt_main.moc"

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    
    VideoCompareUI window;
    window.show();
    
    return app.exec();
}