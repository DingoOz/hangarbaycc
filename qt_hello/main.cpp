#include <QApplication>
#include <QWidget>
#include <QPushButton>
#include <QLabel>
#include <QVBoxLayout>
#include <QProgressBar>
#include <QTimer>

#include <fstream>
#include <string>
#include <sstream>
#include <cstdlib>
#include <ctime>

// Helper to compute CPU usage percentage.
static double getCPUUsagePercent()
{
    static unsigned long long prevTotal = 0, prevIdle = 0;
    std::ifstream statFile("/proc/stat");
    if (!statFile.is_open()) return 0.0;

    std::string line;
    std::getline(statFile, line);
    // Expected format: cpu  user nice system idle iowait irq softirq steal guest guest_nice
    std::istringstream ss(line);
    std::string cpuLabel;
    ss >> cpuLabel; // "cpu"
    unsigned long long values[10];
    for (int i = 0; i < 10 && ss >> values[i]; ++i) {}
    if (ss.fail()) return 0.0;

    unsigned long long total = 0;
    for (int i = 0; i < 10; ++i) total += values[i];
    unsigned long long idle = values[3] + values[4]; // idle + iowait

    if (prevTotal == 0)
    {
        prevTotal = total;
        prevIdle = idle;
        return 0.0; // no data yet
    }

    unsigned long long diffTotal = total - prevTotal;
    unsigned long long diffIdle = idle - prevIdle;

    prevTotal = total;
    prevIdle = idle;

    if (diffTotal == 0) return 0.0;

    double usage = 100.0 * (1.0 - static_cast<double>(diffIdle) / diffTotal);
    if (usage < 0.0) usage = 0.0;
    if (usage > 100.0) usage = 100.0;
    return usage;
}

static double getMemoryUsagePercent()
{
    std::ifstream memFile("/proc/meminfo");
    if (!memFile.is_open()) return 0.0;
    unsigned long totalKb = 0, availableKb = 0;
    std::string line;
    while (std::getline(memFile, line))
    {
        if (line.rfind("MemTotal:", 0) == 0)
        {
            std::istringstream ss(line.substr(9)); // after "MemTotal:"
            ss >> totalKb;
        }
        else if (line.rfind("MemAvailable:", 0) == 0)
        {
            std::istringstream ss(line.substr(13));
            ss >> availableKb;
        }
    }
    if (totalKb == 0) return 0.0;
    unsigned long usedKb = totalKb - availableKb;
    double percent = 100.0 * static_cast<double>(usedKb) / totalKb;
    if (percent < 0.0) percent = 0.0;
    if (percent > 100.0) percent = 100.0;
    return percent;
}

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    QWidget window;
    window.setWindowTitle("Hello Demo");

    QLabel *label = new QLabel("Hello World, this was made locally");
    QPushButton *btn   = new QPushButton("Colourful");

    QProgressBar *cpuBar = new QProgressBar();
    cpuBar->setRange(0, 100);
    cpuBar->setFormat("CPU Usage: %p% ");

    QProgressBar *memBar = new QProgressBar();
    memBar->setRange(0, 100);
    memBar->setFormat("Memory Usage: %p% ");

    QVBoxLayout *layout = new QVBoxLayout(&window);
    layout->addWidget(label);
    layout->addWidget(btn);
    layout->addWidget(cpuBar);
    layout->addWidget(memBar);

    // Seed the random number generator
    std::srand(static_cast<unsigned>(std::time(nullptr)));

    QObject::connect(btn, &QPushButton::clicked,
        [&]() {
            int r = std::rand() % 256;
            int g = std::rand() % 256;
            int b = std::rand() % 256;
            QString style = QString("background-color: rgb(%1,%2,%3);")
                            .arg(r).arg(g).arg(b);
            window.setStyleSheet(style);
        });

    // Update stats every second
    QTimer *timer = new QTimer(&window);
    QObject::connect(timer, &QTimer::timeout,
        [&]() {
            double cpuPerc = getCPUUsagePercent();
            double memPerc = getMemoryUsagePercent();
            cpuBar->setValue(static_cast<int>(cpuPerc + 0.5));
            memBar->setValue(static_cast<int>(memPerc + 0.5));
        });
    timer->start(1000); // 1 Hz

    window.show();
    return app.exec();
}
