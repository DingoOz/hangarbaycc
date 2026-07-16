#include <QApplication>
#include <QMainWindow>
#include <QTextEdit>
#include <QMenuBar>
#include <QMenu>
#include <QToolBar>
#include <QStatusBar>
#include <QFileDialog>
#include <QFontDialog>
#include <QMessageBox>
#include <QInputDialog>
#include <QTextCharFormat>
#include <QTextLength>
#include <QTextBlock>
#include <QKeySequence>
#include <QAction>
#include <QFont>
#include <QTextCursor>
#include <QTextDocument>
#include <QFile>
#include <QTextStream>
#include <QDir>
#include <QDate>
#include <QDateTime>
#include <QPrinter>
#include <QPrintDialog>

class WordProcessor : public QMainWindow
{
    Q_OBJECT

public:
    explicit WordProcessor(QWidget *parent = nullptr)
        : QMainWindow(parent)
        , textEdit(new QTextEdit(this))
        , modified(false)
        , currentFile("")
    {
        setCentralWidget(textEdit);
        textEdit->document()->setUndoRedoEnabled(true);
        updateTitle();
        setupMenus();
        setupToolbar();
        statusBar();
        resize(900, 700);
    }

private slots:
    void newFile()
    {
        if (maybeSave()) {
            currentFile.clear();
            textEdit->clear();
            textEdit->document()->setModified(false);
            modified = false;
            updateTitle();
        }
    }

    void openFile()
    {
        if (!maybeSave()) return;

        QString path = QFileDialog::getOpenFileName(this,
            tr("Open File"), "",
            tr("Text Files (*.txt);;All Files (*)"));
        if (!path.isEmpty()) {
            loadFile(path);
        }
    }

    void saveFile()
    {
        if (currentFile.isEmpty()) {
            saveFileAs();
        } else {
            saveFileTo(currentFile);
        }
    }

    void saveFileAs()
    {
        QString path = QFileDialog::getSaveFileName(this,
            tr("Save File"), "",
            tr("Text Files (*.txt);;All Files (*)"));
        if (!path.isEmpty()) {
            saveFileTo(path);
            currentFile = path;
            updateTitle();
        }
    }

    void printFile()
    {
#ifndef QT_NO_PRINTER
        QPrinter printer;
        QPrintDialog dlg(&printer, this);
        dlg.setWindowTitle(tr("Print Document"));
        if (dlg.exec() == QDialog::Accepted) {
            textEdit->document()->print(&printer);
        }
#endif
    }

    void cutText()
    {
        textEdit->cut();
    }

    void copyText()
    {
        textEdit->copy();
    }

    void pasteText()
    {
        textEdit->paste();
    }

    void deleteText()
    {
        textEdit->textCursor().removeSelectedText();
    }

    void selectAllText()
    {
        textEdit->selectAll();
    }

    void undoText()
    {
        textEdit->undo();
    }

    void redoText()
    {
        textEdit->redo();
    }

    void fontDialog()
    {
        bool ok;
        QFont font = QFontDialog::getFont(&ok, textEdit->font(), this);
        if (ok) {
            textEdit->setCurrentFont(font);
        }
    }

    void centerText()
    {
        textEdit->setAlignment(Qt::AlignCenter);
    }

    void leftAlign()
    {
        textEdit->setAlignment(Qt::AlignLeft);
    }

    void rightAlign()
    {
        textEdit->setAlignment(Qt::AlignRight);
    }

    void justifyText()
    {
        textEdit->setAlignment(Qt::AlignJustify);
    }

    void toggleBold()
    {
        QTextCharFormat fmt;
        fmt.setFontWeight(textEdit->fontWeight() == QFont::Bold
                          ? QFont::Normal : QFont::Bold);
        mergeFormatOnCurrentSelection(fmt);
    }

    void toggleItalic()
    {
        QTextCharFormat fmt;
        fmt.setFontItalic(!textEdit->fontItalic());
        mergeFormatOnCurrentSelection(fmt);
    }

    void toggleUnderline()
    {
        QTextCharFormat fmt;
        fmt.setFontUnderline(!textEdit->fontUnderline());
        mergeFormatOnCurrentSelection(fmt);
    }

    void insertDateTime()
    {
        QTextCursor cursor = textEdit->textCursor();
        cursor.insertText(QDateTime::currentDateTime().toString("yyyy-MM-dd hh:mm:ss"));
        textEdit->setTextCursor(cursor);
    }

    void goToLine()
    {
        bool ok;
        int maxLine = textEdit->document()->blockCount();
        int line = QInputDialog::getInt(this, tr("Go to Line"),
                                        tr("Line number (1-%1):").arg(maxLine),
                                        1, 1, maxLine, 1, &ok);
        if (ok) {
            QTextBlock block = textEdit->document()->findBlockByLineNumber(line - 1);
            if (block.isValid()) {
                QTextCursor cursor(block);
                textEdit->setTextCursor(cursor);
                textEdit->ensureCursorVisible();
            }
        }
    }

    void wordCount()
    {
        QString text = textEdit->toPlainText();
        int words = text.split(QRegExp("\\s+"), Qt::SkipEmptyParts).size();
        int chars = text.length();
        int paragraphs = text.split('\n').size();
        QMessageBox::information(this, tr("Word Count"),
            tr("Words: %1\nCharacters: %2\nParagraphs: %3")
                .arg(words).arg(chars).arg(paragraphs));
    }

    void about()
    {
        QMessageBox::about(this, tr("About Word Processor"),
            tr("<h2>Qt5 Word Processor</h2>"
               "<p>A basic word processor built with Qt5.</p>"
               "<p>Features:</p>"
               "<ul>"
               "<li>Create, open, save, and print documents</li>"
               "<li>Text formatting (bold, italic, underline)</li>"
               "<li>Font selection</li>"
               "<li>Text alignment</li>"
               "<li>Undo/Redo support</li>"
               "<li>Word and character count</li>"
               "</ul>"));
    }

    void updateTitle()
    {
        QString title = tr("Qt5 Word Processor");
        if (!currentFile.isEmpty()) {
            title += " - " + QFileInfo(currentFile).fileName();
        }
        if (modified) {
            title += " [*]";
        }
        setWindowTitle(title);
    }

private:
    void setupMenus()
    {
        // File menu
        QMenu *fileMenu = menuBar()->addMenu(tr("&File"));

        QAction *newAct = new QAction(tr("&New"), this);
        newAct->setShortcut(QKeySequence::New);
        newAct->setStatusTip(tr("Create a new document"));
        connect(newAct, &QAction::triggered, this, &WordProcessor::newFile);
        fileMenu->addAction(newAct);

        QAction *openAct = new QAction(tr("&Open..."), this);
        openAct->setShortcut(QKeySequence::Open);
        openAct->setStatusTip(tr("Open an existing file"));
        connect(openAct, &QAction::triggered, this, &WordProcessor::openFile);
        fileMenu->addAction(openAct);

        QAction *saveAct = new QAction(tr("&Save"), this);
        saveAct->setShortcut(QKeySequence::Save);
        saveAct->setStatusTip(tr("Save the current document"));
        connect(saveAct, &QAction::triggered, this, &WordProcessor::saveFile);
        fileMenu->addAction(saveAct);

        QAction *saveAsAct = new QAction(tr("Save &As..."), this);
        saveAsAct->setStatusTip(tr("Save the document under a new name"));
        connect(saveAsAct, &QAction::triggered, this, &WordProcessor::saveFileAs);
        fileMenu->addAction(saveAsAct);

        fileMenu->addSeparator();

        QAction *printAct = new QAction(tr("&Print..."), this);
        printAct->setShortcut(QKeySequence::Print);
        printAct->setStatusTip(tr("Print the current document"));
        connect(printAct, &QAction::triggered, this, &WordProcessor::printFile);
        fileMenu->addAction(printAct);

        fileMenu->addSeparator();

        QAction *exitAct = new QAction(tr("E&xit"), this);
        exitAct->setShortcut(QKeySequence::Quit);
        exitAct->setStatusTip(tr("Exit the application"));
        connect(exitAct, &QAction::triggered, this, &QWidget::close);
        fileMenu->addAction(exitAct);

        // Edit menu
        QMenu *editMenu = menuBar()->addMenu(tr("&Edit"));

        QAction *undoAct = new QAction(tr("&Undo"), this);
        undoAct->setShortcut(QKeySequence::Undo);
        undoAct->setStatusTip(tr("Undo the last action"));
        connect(undoAct, &QAction::triggered, this, &WordProcessor::undoText);
        editMenu->addAction(undoAct);

        QAction *redoAct = new QAction(tr("&Redo"), this);
        redoAct->setShortcut(QKeySequence::Redo);
        redoAct->setStatusTip(tr("Redo the last action"));
        connect(redoAct, &QAction::triggered, this, &WordProcessor::redoText);
        editMenu->addAction(redoAct);

        editMenu->addSeparator();

        QAction *cutAct = new QAction(tr("Cu&t"), this);
        cutAct->setShortcut(QKeySequence::Cut);
        cutAct->setStatusTip(tr("Cut the selected text"));
        connect(cutAct, &QAction::triggered, this, &WordProcessor::cutText);
        editMenu->addAction(cutAct);

        QAction *copyAct = new QAction(tr("&Copy"), this);
        copyAct->setShortcut(QKeySequence::Copy);
        copyAct->setStatusTip(tr("Copy the selected text"));
        connect(copyAct, &QAction::triggered, this, &WordProcessor::copyText);
        editMenu->addAction(copyAct);

        QAction *pasteAct = new QAction(tr("&Paste"), this);
        pasteAct->setShortcut(QKeySequence::Paste);
        pasteAct->setStatusTip(tr("Paste clipboard content"));
        connect(pasteAct, &QAction::triggered, this, &WordProcessor::pasteText);
        editMenu->addAction(pasteAct);

        QAction *deleteAct = new QAction(tr("Delete"), this);
        deleteAct->setShortcut(QKeySequence::Delete);
        deleteAct->setStatusTip(tr("Delete selected text"));
        connect(deleteAct, &QAction::triggered, this, &WordProcessor::deleteText);
        editMenu->addAction(deleteAct);

        editMenu->addSeparator();

        QAction *selectAct = new QAction(tr("Select &All"), this);
        selectAct->setShortcut(QKeySequence::SelectAll);
        selectAct->setStatusTip(tr("Select all text"));
        connect(selectAct, &QAction::triggered, this, &WordProcessor::selectAllText);
        editMenu->addAction(selectAct);

        QAction *gotoAct = new QAction(tr("&Go to Line..."), this);
        gotoAct->setShortcut(QKeySequence("Ctrl+G"));
        gotoAct->setStatusTip(tr("Go to a specific line"));
        connect(gotoAct, &QAction::triggered, this, &WordProcessor::goToLine);
        editMenu->addAction(gotoAct);

        // Format menu
        QMenu *formatMenu = menuBar()->addMenu(tr("&Format"));

        QAction *fontAct = new QAction(tr("&Font..."), this);
        fontAct->setShortcut(QKeySequence("Ctrl+Shift+F"));
        fontAct->setStatusTip(tr("Choose a font"));
        connect(fontAct, &QAction::triggered, this, &WordProcessor::fontDialog);
        formatMenu->addAction(fontAct);

        formatMenu->addSeparator();

        QAction *boldAct = new QAction(tr("&Bold"), this);
        boldAct->setShortcut(QKeySequence::Bold);
        boldAct->setStatusTip(tr("Toggle bold"));
        connect(boldAct, &QAction::triggered, this, &WordProcessor::toggleBold);
        formatMenu->addAction(boldAct);

        QAction *italicAct = new QAction(tr("I&talic"), this);
        italicAct->setShortcut(QKeySequence::Italic);
        italicAct->setStatusTip(tr("Toggle italic"));
        connect(italicAct, &QAction::triggered, this, &WordProcessor::toggleItalic);
        formatMenu->addAction(italicAct);

        QAction *underlineAct = new QAction(tr("&Underline"), this);
        underlineAct->setShortcut(QKeySequence::Underline);
        underlineAct->setStatusTip(tr("Toggle underline"));
        connect(underlineAct, &QAction::triggered, this, &WordProcessor::toggleUnderline);
        formatMenu->addAction(underlineAct);

        formatMenu->addSeparator();

        QAction *leftAct = new QAction(tr("&Left Align"), this);
        leftAct->setShortcut(QKeySequence("Ctrl+L"));
        leftAct->setStatusTip(tr("Align text to the left"));
        connect(leftAct, &QAction::triggered, this, &WordProcessor::leftAlign);
        formatMenu->addAction(leftAct);

        QAction *centerAct = new QAction(tr("&Center"), this);
        centerAct->setShortcut(QKeySequence("Ctrl+E"));
        centerAct->setStatusTip(tr("Center the text"));
        connect(centerAct, &QAction::triggered, this, &WordProcessor::centerText);
        formatMenu->addAction(centerAct);

        QAction *rightAct = new QAction(tr("Right &Align"), this);
        rightAct->setShortcut(QKeySequence("Ctrl+R"));
        rightAct->setStatusTip(tr("Align text to the right"));
        connect(rightAct, &QAction::triggered, this, &WordProcessor::rightAlign);
        formatMenu->addAction(rightAct);

        QAction *justifyAct = new QAction(tr("Justify"), this);
        justifyAct->setShortcut(QKeySequence("Ctrl+J"));
        justifyAct->setStatusTip(tr("Justify the text"));
        connect(justifyAct, &QAction::triggered, this, &WordProcessor::justifyText);
        formatMenu->addAction(justifyAct);

        // View menu
        QMenu *viewMenu = menuBar()->addMenu(tr("&View"));

        QAction *insertDateAct = new QAction(tr("&Date and Time"), this);
        insertDateAct->setShortcut(QKeySequence("Ctrl+Shift+D"));
        insertDateAct->setStatusTip(tr("Insert current date and time"));
        connect(insertDateAct, &QAction::triggered, this, &WordProcessor::insertDateTime);
        viewMenu->addAction(insertDateAct);

        // Tools menu
        QMenu *toolsMenu = menuBar()->addMenu(tr("&Tools"));

        QAction *wordCountAct = new QAction(tr("&Word Count..."), this);
        wordCountAct->setShortcut(QKeySequence("Ctrl+Shift+W"));
        wordCountAct->setStatusTip(tr("Show word count statistics"));
        connect(wordCountAct, &QAction::triggered, this, &WordProcessor::wordCount);
        toolsMenu->addAction(wordCountAct);

        // Help menu
        QMenu *helpMenu = menuBar()->addMenu(tr("&Help"));

        QAction *aboutAct = new QAction(tr("&About"), this);
        aboutAct->setStatusTip(tr("Show the about dialog"));
        connect(aboutAct, &QAction::triggered, this, &WordProcessor::about);
        helpMenu->addAction(aboutAct);

        // Connect document modification signal
        connect(textEdit->document(), &QTextDocument::modificationChanged,
                this, [this](bool on) {
            modified = on;
            updateTitle();
        });
    }

    void setupToolbar()
    {
        auto addAction = [this](QToolBar *bar, const QString &text, void (WordProcessor::*slot)()) -> QAction * {
            QAction *act = bar->addAction(text);
            connect(act, &QAction::triggered, this, slot);
            return act;
        };

        QToolBar *tb;

        tb = addToolBar(tr("File"));
        addAction(tb, tr("New"), &WordProcessor::newFile);
        addAction(tb, tr("Open"), &WordProcessor::openFile);
        addAction(tb, tr("Save"), &WordProcessor::saveFile);
        addAction(tb, tr("Print"), &WordProcessor::printFile);

        tb = addToolBar(tr("Edit"));
        addAction(tb, tr("Undo"), &WordProcessor::undoText);
        addAction(tb, tr("Redo"), &WordProcessor::redoText);
        tb->addSeparator();
        addAction(tb, tr("Cut"), &WordProcessor::cutText);
        addAction(tb, tr("Copy"), &WordProcessor::copyText);
        addAction(tb, tr("Paste"), &WordProcessor::pasteText);

        tb = addToolBar(tr("Format"));
        addAction(tb, tr("Font"), &WordProcessor::fontDialog);
        addAction(tb, tr("Bold"), &WordProcessor::toggleBold);
        addAction(tb, tr("Italic"), &WordProcessor::toggleItalic);
        addAction(tb, tr("Underline"), &WordProcessor::toggleUnderline);
        tb->addSeparator();
        addAction(tb, tr("Left"), &WordProcessor::leftAlign);
        addAction(tb, tr("Center"), &WordProcessor::centerText);
        addAction(tb, tr("Right"), &WordProcessor::rightAlign);
    }

    void mergeFormatOnCurrentSelection(const QTextCharFormat &format)
    {
        QTextCursor cursor = textEdit->textCursor();
        if (!cursor.hasSelection())
            return;
        cursor.mergeCharFormat(format);
        textEdit->mergeCurrentCharFormat(format);
    }

    bool maybeSave()
    {
        if (textEdit->document()->isModified()) {
            QMessageBox::StandardButton ret = QMessageBox::warning(
                this, tr("Application"),
                tr("The document has been modified.\n"
                   "Do you want to save your changes?"),
                QMessageBox::Save | QMessageBox::Discard | QMessageBox::Cancel);
            if (ret == QMessageBox::Save) {
                saveFile();
                return true;
            } else if (ret == QMessageBox::Cancel) {
                return false;
            }
        }
        return true;
    }

    bool saveFileTo(const QString &fileName)
    {
        QFile file(fileName);
        if (!file.open(QIODevice::WriteOnly | QFile::Text)) {
            QMessageBox::warning(this, tr("Application"),
                tr("Cannot write file %1:\n%2.")
                    .arg(QDir::toNativeSeparators(fileName), file.errorString()));
            return false;
        }
        QTextStream out(&file);
        QApplication::setOverrideCursor(Qt::WaitCursor);
        out << textEdit->toPlainText();
        QApplication::restoreOverrideCursor();
        file.close();
        modified = false;
        updateTitle();
        return true;
    }

    void loadFile(const QString &fileName)
    {
        QFile file(fileName);
        if (!file.open(QIODevice::ReadOnly | QFile::Text)) {
            QMessageBox::warning(this, tr("Application"),
                tr("Cannot read file %1:\n%2.")
                    .arg(QDir::toNativeSeparators(fileName), file.errorString()));
            return;
        }
        QTextStream in(&file);
        QApplication::setOverrideCursor(Qt::WaitCursor);
        textEdit->setPlainText(in.readAll());
        QApplication::restoreOverrideCursor();
        file.close();
        textEdit->document()->setModified(false);
        modified = false;
        currentFile = fileName;
        updateTitle();
    }

    QTextEdit *textEdit;
    bool modified;
    QString currentFile;
};

#include "wordprocessor.moc"

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    app.setApplicationName("Qt5 Word Processor");
    app.setApplicationVersion("1.0");
    WordProcessor wp;
    wp.show();
    return app.exec();
}
