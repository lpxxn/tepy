#include "main_window.hpp"
#include <QApplication>
#include <QFont>

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("Tepy Desktop"));
    QCoreApplication::setApplicationVersion(QStringLiteral("0.2.0"));
    auto font = app.font();
    font.setFamilies({QStringLiteral("Microsoft YaHei UI"), QStringLiteral("PingFang SC"),
                      QStringLiteral("Noto Sans CJK SC")});
    app.setFont(font);
    tepy::desktop::MainWindow window;
    if (app.arguments().contains(QStringLiteral("--self-check")))
        return 0;
    window.show();
    return app.exec();
}
