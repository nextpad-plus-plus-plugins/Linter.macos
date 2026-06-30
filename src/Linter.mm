// Linter — macOS (Nextpad++) port
// Original Windows plugin: "Notepad++ Linter" by Vladimir Soshkin <deadem@gmail.com>
// (MIT, 2016).  https://github.com/deadem/notepadpp-linter
//
// Runs realtime checkstyle-compatible linters (jshint / eslint / jscs / phpcs /
// csslint …) on the current document via external command-line tools, parses
// their checkstyle XML output, and marks the problems in the editor with a
// Scintilla indicator.  A settings dialog maps file-extension → linter command.
//
// The linting *logic* is ported faithfully from the Windows source; only the
// platform layer changes:
//
//   Win32 / MSXML6                         macOS / Cocoa
//   ─────────────────────────────────────  ───────────────────────────────────
//   CreateProcess + CreatePipe (file.cpp)  NSTask + NSPipe (run via /bin/sh -lc
//                                          so global linters on PATH resolve)
//   MSXML6 COM (IXMLDOMDocument2)           NSXMLDocument + nodesForXPath
//   _beginthreadex + GetExitCodeThread      dispatch_async to a background queue,
//     polled in beNotified                  results applied back on the main queue
//   CreateTimerQueueTimer (300 ms debounce) dispatch_after with a coalescing token
//   Native status-bar HWND write            SCI_CALLTIPSHOW at the error position
//     (showTooltip, file.cpp)               (NPPM_SETSTATUSBAR is a host no-op —
//                                            see the note in showTooltip)
//   ::SendMessage(scintilla / npp, …)       nppData._sendMessage(handle, …)
//   linter.xml via MSXML, "Edit config"     same linter.xml parsed via NSXML,
//     opens it with NPPM_DOOPEN             plus a programmatic AppKit settings
//                                            dialog editing the same file
//
// The Scintilla indicator id, the UTF-8 column-offset arithmetic, the
// alpha/colour handling and the per-extension command matching are all kept
// byte-for-byte equivalent to the original.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <dlfcn.h>
#include <cstring>
#include <map>
#include <string>
#include <vector>

// ─────────────────────────────────────────────────────────────────────────────
// Constants & model (mirrors XmlParser.h)
// ─────────────────────────────────────────────────────────────────────────────

// Matches the Windows  SCE_SQUIGGLE_UNDERLINE_RED = INDIC_CONTAINER + 2.
static const int kLinterIndicator = INDIC_CONTAINER + 2;

static const char *PLUGIN_NAME = "Linter";

namespace {

struct LinterError {           // == XmlParser::Error
    int line = 0;
    int column = 0;
    std::string message;
};

struct LinterRule {            // == XmlParser::Linter
    std::string extension;     // e.g. ".js"
    std::string command;       // e.g. "eslint --format checkstyle"
    bool useStdin = false;
};

struct LinterSettings {        // == XmlParser::Settings
    int color = -1;            // Scintilla BGR (already byte-swapped), -1 = default
    int alpha = -1;            // 0..255, -1 = default (box style)
    std::vector<LinterRule> rules;
};

NppData nppData;
FuncItem funcItem[3];

// Plugin state (mirrors the file-scope globals in linter.cpp).
LinterSettings gSettings;
std::vector<LinterError> gErrors;            // results of the last run
std::map<intptr_t, std::string> gErrorText;  // caret position → message (== errorText)
bool gReady = false;

// ─────────────────────────────────────────────────────────────────────────────
// Scintilla / host helpers
// ─────────────────────────────────────────────────────────────────────────────

NppHandle curScintilla() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    if (which == -1) return 0;
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

// SendEditor() — to the active Scintilla view.
intptr_t sci(uint32_t msg, uintptr_t wp = 0, intptr_t lp = 0) {
    return nppData._sendMessage(curScintilla(), msg, wp, lp);
}

// SendApp() — to the Nextpad++ main handle.
intptr_t app(uint32_t msg, uintptr_t wp = 0, intptr_t lp = 0) {
    return nppData._sendMessage(nppData._nppHandle, msg, wp, lp);
}

// GetFilePart() — NPPM_GETFILENAME / NPPM_GETEXTPART / NPPM_GETCURRENTDIRECTORY.
std::string filePart(uint32_t part) {
    char buff[2048];
    buff[0] = '\0';
    app(part, sizeof(buff) - 1, (intptr_t)buff);
    return std::string(buff);
}

// getDocumentText() — full buffer as UTF-8.
std::string documentText() {
    intptr_t length = sci(SCI_GETLENGTH);
    std::string text;
    text.resize((size_t)length + 1);
    sci(SCI_GETTEXT, (uintptr_t)(length + 1), (intptr_t)&text[0]);
    text.resize((size_t)length);   // drop the NUL Scintilla appended
    return text;
}

// getLineText(line).
std::string lineText(int line) {
    intptr_t length = sci(SCI_LINELENGTH, (uintptr_t)line);
    if (length <= 0) return std::string();
    std::string text;
    text.resize((size_t)length + 1);
    sci(SCI_GETLINE, (uintptr_t)line, (intptr_t)&text[0]);
    text.resize((size_t)length);
    return text;
}

intptr_t positionForLine(int line) {
    return sci(SCI_POSITIONFROMLINE, (uintptr_t)line);
}

// ── Encoding::utfOffset (ported verbatim from encoding.cpp) ──────────────────
// Converts a 1-based-decremented "unicode" column from the linter into a
// Scintilla byte offset within the (UTF-8) line, skipping CR/LF exactly as the
// Windows code did.
int utfOffset(const std::string &utf8, int unicodeOffset) {
    int result = 0;
    std::string::const_iterator i = utf8.begin(), end = utf8.end();
    while (unicodeOffset > 0 && i != end) {
        if ((*i & 0xC0) == 0xC0 && unicodeOffset == 1) {
            break;
        }
        if ((*i & 0x80) == 0 || (*i & 0xC0) == 0x80) {
            --unicodeOffset;
        }
        ++i;
        if (i != end && *i != 0x0D && *i != 0x0A) {
            ++result;
        }
    }
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// Indicator drawing (mirrors ShowError / InitErrors / ClearErrors)
// ─────────────────────────────────────────────────────────────────────────────

// ShowError(start, end, off) — fill (off=true) or clear (off=false) the
// linter indicator over [start, end).
void showError(intptr_t start, intptr_t end, bool off) {
    intptr_t oldid = sci(SCI_GETINDICATORCURRENT);
    sci(SCI_SETINDICATORCURRENT, (uintptr_t)kLinterIndicator);
    if (off) {
        sci(SCI_INDICATORFILLRANGE, (uintptr_t)start, (end - start));
    } else {
        sci(SCI_INDICATORCLEARRANGE, (uintptr_t)start, (end - start));
    }
    sci(SCI_SETINDICATORCURRENT, (uintptr_t)oldid);
}

void initErrors() {
    sci(SCI_INDICSETSTYLE, (uintptr_t)kLinterIndicator, INDIC_BOX);
    sci(SCI_INDICSETFORE,  (uintptr_t)kLinterIndicator, 0x0000ff);

    if (!gSettings.rules.empty() && (gSettings.alpha != -1 || gSettings.color != -1)) {
        sci(SCI_INDICSETSTYLE, (uintptr_t)kLinterIndicator, INDIC_ROUNDBOX);
        if (gSettings.alpha != -1) {
            sci(SCI_INDICSETALPHA, (uintptr_t)kLinterIndicator, (intptr_t)gSettings.alpha);
        }
        if (gSettings.color != -1) {
            sci(SCI_INDICSETFORE, (uintptr_t)kLinterIndicator, (intptr_t)gSettings.color);
        }
    }
}

void clearErrors() {
    intptr_t length = sci(SCI_GETLENGTH);
    showError(0, length, false);
    sci(SCI_ANNOTATIONCLEARALL);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tooltip surface (replaces showTooltip / native status-bar manipulation)
//
// The Windows plugin found the editor's native msctls_statusbar32 child window
// and wrote the error message for the current caret position into it.  On
// macOS the host status bar is not a child HWND a plugin can poke, and
// NPPM_SETSTATUSBAR is declared-but-not-implemented (host no-op).  We therefore
// surface the per-position message as a Scintilla call tip anchored at the
// caret — an in-editor surface that is at least as visible as the original.
// ─────────────────────────────────────────────────────────────────────────────
void showTooltip() {
    if (!gReady) return;
    intptr_t position = sci(SCI_GETCURRENTPOS);
    auto it = gErrorText.find(position);
    if (it != gErrorText.end()) {
        sci(SCI_CALLTIPSHOW, (uintptr_t)position, (intptr_t)it->second.c_str());
    } else if (sci(SCI_CALLTIPACTIVE)) {
        sci(SCI_CALLTIPCANCEL);
    }
}

void showMessage(const std::string &message) {
    if (message.empty()) return;
    intptr_t position = sci(SCI_GETCURRENTPOS);
    sci(SCI_CALLTIPSHOW, (uintptr_t)position, (intptr_t)message.c_str());
}

// ─────────────────────────────────────────────────────────────────────────────
// Config dir / linter.xml path  (mirrors initConfig + getIniFileName)
// ─────────────────────────────────────────────────────────────────────────────
std::string iniFilePath() {
    char dir[2048];
    dir[0] = '\0';
    app(NPPM_GETPLUGINSCONFIGDIR, sizeof(dir) - 1, (intptr_t)dir);
    @autoreleasepool {
        NSString *d = [NSString stringWithUTF8String:dir];
        if (d.length == 0) {
            d = [NSHomeDirectory() stringByAppendingPathComponent:@".nextpad++/plugins/Config"];
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:d
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        return std::string([[d stringByAppendingPathComponent:@"linter.xml"] UTF8String]);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// XML: parse checkstyle <error …> output   (mirrors XmlParser::getErrors)
// ─────────────────────────────────────────────────────────────────────────────
std::vector<LinterError> parseErrors(const std::string &xml, std::string *parseFailure) {
    std::vector<LinterError> errors;
    @autoreleasepool {
        if (xml.empty()) return errors;
        NSString *s = [NSString stringWithUTF8String:xml.c_str()];
        if (!s) {  // not valid UTF-8 — fall back to a lossy interpretation
            NSData *d = [NSData dataWithBytes:xml.data() length:xml.size()];
            s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
        }
        if (s.length == 0) return errors;

        NSError *err = nil;
        NSXMLDocument *doc = [[NSXMLDocument alloc] initWithXMLString:s options:0 error:&err];
        if (!doc) {
            // == "Invalid output format. Only checkstyle-compatible output allowed."
            if (parseFailure) {
                *parseFailure = "Linter: Invalid output format. "
                                "Only checkstyle-compatible output allowed.";
            }
            return errors;
        }

        // <error line="12" column="19" severity="error" message="…" source="jscs" />
        NSArray *nodes = [doc nodesForXPath:@"//error" error:&err];
        for (NSXMLElement *e in nodes) {
            if (![e isKindOfClass:[NSXMLElement class]]) continue;
            LinterError le;
            NSXMLNode *ln = [e attributeForName:@"line"];
            NSXMLNode *col = [e attributeForName:@"column"];
            NSXMLNode *msg = [e attributeForName:@"message"];
            le.line    = ln  ? [[ln stringValue]  intValue] : 0;
            le.column  = col ? [[col stringValue] intValue] : 0;
            le.message = msg ? std::string([[msg stringValue] UTF8String]) : std::string();
            errors.push_back(le);
        }
    }
    return errors;
}

// ─────────────────────────────────────────────────────────────────────────────
// XML: parse linter.xml settings   (mirrors XmlParser::getLinters)
// ─────────────────────────────────────────────────────────────────────────────
LinterSettings parseSettings(const std::string &file, std::string *loadFailure) {
    LinterSettings settings;
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:file.c_str()];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) {
            // No file yet — empty settings (the caller warns the user).
            return settings;
        }
        NSError *err = nil;
        NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:&err];
        if (!doc) {
            if (loadFailure) {
                *loadFailure = "Linter: linter.xml load error. Check file format.";
            }
            return settings;
        }

        // Optional <style color="RRGGBB" alpha="N" />.
        NSArray *styleNodes = [doc nodesForXPath:@"//style" error:&err];
        if (styleNodes.count > 0) {
            NSXMLElement *style = (NSXMLElement *)styleNodes[0];
            if ([style isKindOfClass:[NSXMLElement class]]) {
                NSXMLNode *alpha = [style attributeForName:@"alpha"];
                if (alpha) {
                    NSString *a = [alpha stringValue];
                    if (a.length) settings.alpha = [a intValue];
                }
                NSXMLNode *colorNode = [style attributeForName:@"color"];
                if (colorNode) {
                    NSString *c = [colorNode stringValue];
                    if (c.length) {
                        unsigned int color = 0;
                        [[NSScanner scannerWithString:c] scanHexInt:&color];
                        // Reverse RGB → Scintilla's little-endian BGR (verbatim).
                        int v = color & 0xFF;
                        v <<= 8; color >>= 8; v |= color & 0xFF;
                        v <<= 8; color >>= 8; v |= color & 0xFF;
                        settings.color = v;
                    }
                }
            }
        }

        // <linter extension=".js" command="…" stdin="1"/>
        NSArray *linterNodes = [doc nodesForXPath:@"//linter" error:&err];
        for (NSXMLElement *e in linterNodes) {
            if (![e isKindOfClass:[NSXMLElement class]]) continue;
            LinterRule rule;
            NSXMLNode *ext = [e attributeForName:@"extension"];
            NSXMLNode *cmd = [e attributeForName:@"command"];
            NSXMLNode *std = [e attributeForName:@"stdin"];
            if (ext) rule.extension = std::string([[ext stringValue] UTF8String]);
            if (cmd) rule.command   = std::string([[cmd stringValue] UTF8String]);
            if (std) {
                NSString *sv = [std stringValue];
                rule.useStdin = ([sv isEqualToString:@"1"] ||
                                 [[sv lowercaseString] isEqualToString:@"true"] ||
                                 [[sv lowercaseString] isEqualToString:@"yes"]);
            }
            settings.rules.push_back(rule);
        }
    }
    return settings;
}

// ─────────────────────────────────────────────────────────────────────────────
// Run one linter via NSTask  (mirrors File::exec + CreateProcess/CreatePipe)
//
// The Windows code passed the whole command line to CreateProcess (which does
// its own tokenisation and uses the inherited environment / PATH).  The macOS
// faithful equivalent is /bin/sh -lc "<command>" :
//   • -l gives a login shell so PATH includes node/npm global bins, Homebrew,
//     pyenv, etc. — essential for "first run" to find eslint/phpcs without the
//     user hard-coding an absolute path (Windows users likewise gave bare
//     command names that the shell/PATH resolved).
//   • the document is written to a temp file appended to the command (unless
//     stdin mode), exactly like file.cpp.
// Returns the linter's stdout.
// ─────────────────────────────────────────────────────────────────────────────
std::string runLinter(const std::string &command,
                      bool useStdin,
                      const std::string &text,
                      const std::string &fileName,
                      const std::string &directory,
                      std::string *execFailure) {
    @autoreleasepool {
        std::string commandLine = command;
        NSString *tempFile = nil;

        if (!useStdin) {
            // File::write — temp file next to (or near) the document.
            NSString *dir = directory.empty()
                ? NSTemporaryDirectory()
                : [NSString stringWithUTF8String:directory.c_str()];
            NSString *base = fileName.empty() ? @"linter" : [NSString stringWithUTF8String:fileName.c_str()];
            tempFile = [dir stringByAppendingPathComponent:
                        [base stringByAppendingString:@".temp.linter.file.tmp"]];
            NSData *d = [NSData dataWithBytes:text.data() length:text.size()];
            if (![d writeToFile:tempFile atomically:NO]) {
                // Fall back to the system temp dir if the doc dir is unwritable.
                tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:
                            [base stringByAppendingString:@".temp.linter.file.tmp"]];
                [d writeToFile:tempFile atomically:NO];
            }
            // Append the quoted file path, exactly like File::exec.
            commandLine += " \"";
            commandLine += [tempFile UTF8String];
            commandLine += "\"";
        }

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
        task.arguments = @[ @"-l", @"-c", [NSString stringWithUTF8String:commandLine.c_str()] ];

        if (!directory.empty()) {
            NSString *wd = [NSString stringWithUTF8String:directory.c_str()];
            if ([[NSFileManager defaultManager] fileExistsAtPath:wd]) {
                task.currentDirectoryURL = [NSURL fileURLWithPath:wd];
            }
        }

        NSPipe *stdoutPipe = [NSPipe pipe];
        NSPipe *stderrPipe = [NSPipe pipe];
        task.standardOutput = stdoutPipe;
        task.standardError  = stderrPipe;

        NSPipe *stdinPipe = nil;
        if (useStdin) {
            stdinPipe = [NSPipe pipe];
            task.standardInput = stdinPipe;
        }

        NSError *launchErr = nil;
        if (![task launchAndReturnError:&launchErr]) {
            if (execFailure) {
                *execFailure = std::string("Linter: Can't execute command: ") + commandLine;
            }
            if (tempFile) [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
            return std::string();
        }

        NSFileHandle *outHandle = stdoutPipe.fileHandleForReading;
        if (useStdin) {
            // Feed stdin on a background thread, then drain stdout, to avoid a
            // pipe-buffer deadlock (matches file.cpp's "close all the handles"
            // ordering).
            NSData *inputData = [NSData dataWithBytes:text.data() length:text.size()];
            NSFileHandle *inH = stdinPipe.fileHandleForWriting;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                @try { [inH writeData:inputData]; } @catch (...) {}
                @try { [inH closeFile]; } @catch (...) {}
            });
        }

        NSData *outData = [outHandle readDataToEndOfFile];
        [task waitUntilExit];

        if (tempFile) {
            [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
        }

        if (!outData) return std::string();
        return std::string((const char *)outData.bytes, outData.length);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Apply the parsed errors to the editor  (mirrors DrawBoxes)
// Runs on the main thread.
// ─────────────────────────────────────────────────────────────────────────────
void drawBoxes() {
    clearErrors();
    gErrorText.clear();
    if (!gErrors.empty()) {
        initErrors();
    }
    for (const LinterError &error : gErrors) {
        intptr_t position = positionForLine(error.line - 1);
        position += utfOffset(lineText(error.line - 1), error.column - 1);
        gErrorText[position] = error.message;
        showError(position, position + 1, true);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Asynchronous lint run  (mirrors AsyncCheck + RunThread + Check, debounced)
// ─────────────────────────────────────────────────────────────────────────────

// Collect the commands whose extension matches the current document.
bool collectCommands(std::vector<std::pair<std::string, bool>> &commands) {
    std::string ext = filePart(NPPM_GETEXTPART);
    bool any = false;
    for (const LinterRule &rule : gSettings.rules) {
        if (ext == rule.extension) {
            commands.emplace_back(rule.command, rule.useStdin);
            any = true;
        }
    }
    return any;
}

void runCheckNow() {
    if (!gReady) return;

    std::vector<std::pair<std::string, bool>> commands;
    if (!collectCommands(commands)) {
        // No linter for this extension — make sure stale marks are gone.
        if (!gErrors.empty() || !gErrorText.empty()) {
            gErrors.clear();
            drawBoxes();
        }
        return;
    }

    // Snapshot everything the worker needs while on the main thread.
    std::string text = documentText();
    std::string fileName  = filePart(NPPM_GETFILENAME);
    std::string directory = filePart(NPPM_GETCURRENTDIRECTORY);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        std::vector<LinterError> found;
        std::string failure;
        for (const auto &command : commands) {
            std::string execFailure;
            std::string xml = runLinter(command.first, command.second, text,
                                        fileName, directory, &execFailure);
            if (!execFailure.empty()) {
                if (failure.empty()) failure = execFailure;
                continue;
            }
            std::string parseFailure;
            std::vector<LinterError> parsed = parseErrors(xml, &parseFailure);
            if (!parseFailure.empty() && failure.empty()) failure = parseFailure;
            found.insert(found.end(), parsed.begin(), parsed.end());
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            gErrors = found;
            drawBoxes();
            if (!failure.empty()) showMessage(failure);
        });
    });
}

// Check() — 300 ms debounce via a coalescing token (replaces the timer queue).
void scheduleCheck() {
    static int64_t token = 0;
    int64_t mine = ++token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (mine == token) runCheckNow();
    });
}

// initLinters() — load linter.xml, warn if empty/broken.
void initLinters() {
    std::string failure;
    gSettings = parseSettings(iniFilePath(), &failure);
    if (!failure.empty()) {
        showMessage(failure);
    } else if (gSettings.rules.empty()) {
        showMessage("Linter: Empty linter.xml.");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// linter.xml serialisation (for the settings dialog) + a default seed
// ─────────────────────────────────────────────────────────────────────────────
std::string xmlEscape(const std::string &in) {
    std::string out;
    for (char c : in) {
        switch (c) {
            case '&':  out += "&amp;";  break;
            case '<':  out += "&lt;";   break;
            case '>':  out += "&gt;";   break;
            case '"':  out += "&quot;"; break;
            default:   out += c;        break;
        }
    }
    return out;
}

void writeSettings(const LinterSettings &settings) {
    std::string xml = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n<NotepadPlus>\n";
    if (settings.color != -1 || settings.alpha != -1) {
        // Convert Scintilla BGR back to RRGGBB for the file (inverse of parse).
        int bgr = settings.color;
        char hex[8] = "000000";
        if (bgr != -1) {
            int r = bgr & 0xFF;
            int g = (bgr >> 8) & 0xFF;
            int b = (bgr >> 16) & 0xFF;
            snprintf(hex, sizeof(hex), "%02X%02X%02X", r, g, b);
        }
        xml += "  <style";
        if (settings.color != -1) { xml += " color=\""; xml += hex; xml += "\""; }
        if (settings.alpha != -1) { xml += " alpha=\"" + std::to_string(settings.alpha) + "\""; }
        xml += " />\n";
    }
    for (const LinterRule &r : settings.rules) {
        xml += "  <linter extension=\"" + xmlEscape(r.extension) + "\"";
        xml += " command=\"" + xmlEscape(r.command) + "\"";
        if (r.useStdin) xml += " stdin=\"1\"";
        xml += " />\n";
    }
    xml += "</NotepadPlus>\n";

    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:iniFilePath().c_str()];
        NSData *d = [NSData dataWithBytes:xml.data() length:xml.size()];
        [d writeToFile:path atomically:YES];
    }
}

// Materialise a documented default linter.xml on first run if none exists, so
// the editor "Edit config (XML)" command opens something useful.
void ensureDefaultConfig() {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:iniFilePath().c_str()];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
        NSString *seed =
            @"<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n"
             "<NotepadPlus>\n"
             "  <!-- Map a file extension to a checkstyle-compatible linter command.\n"
             "       Commands run through a login shell, so a bare name on your PATH\n"
             "       works (e.g. eslint, jshint, phpcs). Add stdin=\"1\" to lint from\n"
             "       stdin instead of a temp file. Edit via Plugins > Linter, or here. -->\n"
             "  <!-- <style color=\"0000FF\" alpha=\"100\" /> -->\n"
             "  <!-- <linter extension=\".js\"  command=\"eslint --format checkstyle\" stdin=\"1\" /> -->\n"
             "  <!-- <linter extension=\".js\"  command=\"jshint --reporter=checkstyle\" /> -->\n"
             "  <!-- <linter extension=\".php\" command=\"phpcs --report=checkstyle\" /> -->\n"
             "  <!-- <linter extension=\".css\" command=\"csslint --format=checkstyle-xml\" /> -->\n"
             "</NotepadPlus>\n";
        [seed writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

} // namespace

// ─────────────────────────────────────────────────────────────────────────────
// Settings dialog — programmatic AppKit modal NSWindow.
//
// The Windows plugin exposed its settings purely as the linter.xml file (the
// "Edit config" command opened it in the editor). We provide a real dialog
// editing the same model — an editable table of extension / command / stdin
// rows plus the optional indicator colour & alpha — and still offer an
// "Edit config (XML)" command (= the original NPPM_DOOPEN behaviour).
// ─────────────────────────────────────────────────────────────────────────────
@interface LinterSettingsController : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) NSButton *colorCheck;
@property(nonatomic, strong) NSColorWell *colorWell;
@property(nonatomic, strong) NSButton *alphaCheck;
@property(nonatomic, strong) NSTextField *alphaField;
@end

@implementation LinterSettingsController {
    std::vector<LinterRule> _rules;
}

- (void)loadModel {
    _rules = gSettings.rules;
}

- (void)build {
    const CGFloat W = 620, H = 380;
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                          styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Linter Settings";
    _window.delegate = self;
    _window.releasedWhenClosed = NO;
    NSView *root = _window.contentView;

    NSTextField *intro = [NSTextField wrappingLabelWithString:
        @"Map a file extension to a checkstyle-compatible linter command "
         "(jshint, eslint, jscs, phpcs, csslint …). Commands run through a "
         "login shell, so a bare name on your PATH works. Tick “stdin” "
         "to feed the document on standard input instead of a temp file."];
    intro.frame = NSMakeRect(16, H - 64, W - 32, 48);
    [root addSubview:intro];

    // ── Table of rules ──
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 104, W - 32, H - 184)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    _table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.allowsMultipleSelection = NO;

    NSTableColumn *extCol = [[NSTableColumn alloc] initWithIdentifier:@"extension"];
    extCol.title = @"Extension"; extCol.width = 90; extCol.editable = YES;
    [_table addTableColumn:extCol];

    NSTableColumn *cmdCol = [[NSTableColumn alloc] initWithIdentifier:@"command"];
    cmdCol.title = @"Command"; cmdCol.width = 380; cmdCol.editable = YES;
    [_table addTableColumn:cmdCol];

    NSTableColumn *stdinCol = [[NSTableColumn alloc] initWithIdentifier:@"stdin"];
    stdinCol.title = @"stdin"; stdinCol.width = 50; stdinCol.editable = YES;
    NSButtonCell *check = [[NSButtonCell alloc] init];
    check.buttonType = NSButtonTypeSwitch;
    check.title = @"";
    stdinCol.dataCell = check;
    [_table addTableColumn:stdinCol];

    _table.dataSource = self;
    _table.delegate = self;
    scroll.documentView = _table;
    [root addSubview:scroll];

    // ── Add / Remove ──
    NSButton *add = [NSButton buttonWithTitle:@"Add" target:self action:@selector(addRow:)];
    add.frame = NSMakeRect(16, 68, 72, 28);
    [root addSubview:add];
    NSButton *del = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(removeRow:)];
    del.frame = NSMakeRect(92, 68, 84, 28);
    [root addSubview:del];

    // ── Indicator colour / alpha ──
    _colorCheck = [NSButton checkboxWithTitle:@"Colour" target:nil action:nil];
    _colorCheck.frame = NSMakeRect(196, 72, 70, 20);
    [root addSubview:_colorCheck];
    _colorWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(266, 68, 44, 26)];
    [root addSubview:_colorWell];

    _alphaCheck = [NSButton checkboxWithTitle:@"Alpha" target:nil action:nil];
    _alphaCheck.frame = NSMakeRect(326, 72, 64, 20);
    [root addSubview:_alphaCheck];
    _alphaField = [[NSTextField alloc] initWithFrame:NSMakeRect(390, 70, 56, 22)];
    _alphaField.placeholderString = @"0-255";
    [root addSubview:_alphaField];

    // ── OK / Cancel ──
    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(ok:)];
    ok.frame = NSMakeRect(W - 180, 18, 78, 30);
    ok.keyEquivalent = @"\r";
    [root addSubview:ok];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(W - 96, 18, 78, 30);
    cancel.keyEquivalent = @"\e";
    [root addSubview:cancel];

    [self loadStyleControls];
}

- (void)loadStyleControls {
    BOOL hasColor = (gSettings.color != -1);
    _colorCheck.state = hasColor ? NSControlStateValueOn : NSControlStateValueOff;
    if (hasColor) {
        int bgr = gSettings.color;
        CGFloat r = (bgr & 0xFF) / 255.0;
        CGFloat g = ((bgr >> 8) & 0xFF) / 255.0;
        CGFloat b = ((bgr >> 16) & 0xFF) / 255.0;
        _colorWell.color = [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0];
    } else {
        _colorWell.color = [NSColor colorWithCalibratedRed:0 green:0 blue:1 alpha:1.0];
    }
    BOOL hasAlpha = (gSettings.alpha != -1);
    _alphaCheck.state = hasAlpha ? NSControlStateValueOn : NSControlStateValueOff;
    _alphaField.stringValue = hasAlpha ? [NSString stringWithFormat:@"%d", gSettings.alpha] : @"";
}

// ── NSTableViewDataSource ──
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_rules.size(); }

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_rules.size()) return nil;
    const LinterRule &r = _rules[(size_t)row];
    NSString *ident = col.identifier;
    if ([ident isEqualToString:@"extension"]) return [NSString stringWithUTF8String:r.extension.c_str()];
    if ([ident isEqualToString:@"command"])   return [NSString stringWithUTF8String:r.command.c_str()];
    if ([ident isEqualToString:@"stdin"])      return @(r.useStdin ? 1 : 0);
    return nil;
}

- (void)tableView:(NSTableView *)tv setObjectValue:(id)obj forTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_rules.size()) return;
    LinterRule &r = _rules[(size_t)row];
    NSString *ident = col.identifier;
    if ([ident isEqualToString:@"extension"]) r.extension = obj ? std::string([obj UTF8String]) : std::string();
    else if ([ident isEqualToString:@"command"]) r.command = obj ? std::string([obj UTF8String]) : std::string();
    else if ([ident isEqualToString:@"stdin"]) r.useStdin = [obj boolValue];
}

// ── Buttons ──
- (void)addRow:(id)sender {
    LinterRule r; r.extension = ".js"; r.command = ""; r.useStdin = false;
    _rules.push_back(r);
    [_table reloadData];
    NSInteger last = (NSInteger)_rules.size() - 1;
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:last] byExtendingSelection:NO];
    [_table editColumn:0 row:last withEvent:nil select:YES];
}

- (void)removeRow:(id)sender {
    NSInteger row = _table.selectedRow;
    if (row < 0 || row >= (NSInteger)_rules.size()) return;
    _rules.erase(_rules.begin() + row);
    [_table reloadData];
}

- (void)ok:(id)sender {
    [_window makeFirstResponder:nil];  // commit any in-progress cell edit

    LinterSettings out;
    // Drop fully-empty rows; keep order.
    for (const LinterRule &r : _rules) {
        if (r.extension.empty() && r.command.empty()) continue;
        out.rules.push_back(r);
    }
    if (_colorCheck.state == NSControlStateValueOn) {
        NSColor *c = [_colorWell.color colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
        int r = (int)lround(c.redComponent   * 255.0);
        int g = (int)lround(c.greenComponent * 255.0);
        int b = (int)lround(c.blueComponent  * 255.0);
        // Store as Scintilla BGR (matches parseSettings output).
        out.color = (b << 16) | (g << 8) | r;
    }
    if (_alphaCheck.state == NSControlStateValueOn) {
        int a = _alphaField.integerValue;
        if (a < 0) a = 0; if (a > 255) a = 255;
        out.alpha = a;
    }

    gSettings = out;
    writeSettings(gSettings);
    initErrors();          // re-apply the indicator style with the new colour/alpha
    runCheckNow();         // re-lint immediately with the new rules
    [NSApp stopModal];
}

- (void)cancel:(id)sender { [NSApp stopModal]; }
- (void)windowWillClose:(NSNotification *)n { [NSApp stopModal]; }

- (void)run {
    [self loadModel];
    [self build];
    [_window center];
    [NSApp runModalForWindow:_window];
    [_window orderOut:nil];
}
@end

// ─────────────────────────────────────────────────────────────────────────────
// Menu commands
// ─────────────────────────────────────────────────────────────────────────────
static void cmdSettings() {
    @autoreleasepool {
        LinterSettingsController *c = [[LinterSettingsController alloc] init];
        [c run];
    }
}

// "Edit config" — the original behaviour: open linter.xml in the editor.
static void cmdEditConfig() {
    @autoreleasepool {
        ensureDefaultConfig();
        std::string path = iniFilePath();
        app(NPPM_DOOPEN, 0, (intptr_t)path.c_str());
    }
}

static void cmdRecheck() {
    runCheckNow();
}

// ─────────────────────────────────────────────────────────────────────────────
// Plugin exports
// ─────────────────────────────────────────────────────────────────────────────
extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    memset(funcItem, 0, sizeof(funcItem));

    strncpy(funcItem[0]._itemName, "Settings…", NPP_MENU_ITEM_SIZE - 1);
    funcItem[0]._pFunc = cmdSettings;
    funcItem[0]._pShKey = nullptr;

    strncpy(funcItem[1]._itemName, "Edit config (XML)", NPP_MENU_ITEM_SIZE - 1);
    funcItem[1]._pFunc = cmdEditConfig;
    funcItem[1]._pShKey = nullptr;

    strncpy(funcItem[2]._itemName, "Lint Now", NPP_MENU_ITEM_SIZE - 1);
    funcItem[2]._pFunc = cmdRecheck;
    funcItem[2]._pShKey = nullptr;

    ensureDefaultConfig();
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = (int)(sizeof(funcItem) / sizeof(funcItem[0]));
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *notifyCode) {
    if (!notifyCode) return;

    switch (notifyCode->nmhdr.code) {
        case NPPN_READY:
            initLinters();
            initErrors();
            gReady = true;
            scheduleCheck();
            return;

        case NPPN_SHUTDOWN:
            return;

        default:
            break;
    }

    if (!gReady) return;

    switch (notifyCode->nmhdr.code) {
        case NPPN_BUFFERACTIVATED:
            // New buffer became active → re-lint (== isBufferChanged path).
            initErrors();
            scheduleCheck();
            break;

        case SCN_MODIFIED:
            if (notifyCode->modificationType & (SC_MOD_DELETETEXT | SC_MOD_INSERTTEXT)) {
                scheduleCheck();
            }
            break;

        case SCN_UPDATEUI:
            showTooltip();   // show the message for the caret position, if any
            break;

        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t Message, uintptr_t wParam, intptr_t lParam) {
    (void)Message; (void)wParam; (void)lParam;
    return 1;
}
