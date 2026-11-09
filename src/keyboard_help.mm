#include "keyboard_help.h"

#include "line_introspect.h"

#include <QtCore/QEvent>
#include <QtCore/QPointer>
#include <QtGui/QKeyEvent>
#include <QtWidgets/QApplication>
#include <QtWidgets/QPlainTextEdit>
#include <QtWidgets/QPushButton>
#include <QtWidgets/QVBoxLayout>
#include <QtWidgets/QWidget>

namespace line_a11y {
namespace {

const char kWindowName[] = "lineMR_keyboard_help";
const char kTextName[] = "lineMR_keyboard_help_text";

// English, Thai, Japanese, Simplified Chinese, Traditional Chinese (UiLanguage's order).
using Texts = const char *const[5];

struct Row {
    const char *keys; // the keys as they are named on a Mac keyboard; null: `text` is a heading
    Texts text;
};

const Row kRows[] = {
    { nullptr, { "This help", "หน้าช่วยเหลือนี้", "このヘルプ", "本帮助", "本說明" } },
    { "Command+Shift+K", { "Open this keyboard help", "เปิดหน้ารายการแป้นพิมพ์นี้", "このキーボードヘルプを開く", "打开本键盘帮助", "開啟本鍵盤說明" } },
    { "Up / Down", { "Read this page line by line", "อ่านหน้านี้ทีละบรรทัด", "このページを 1 行ずつ読む", "逐行阅读本页", "逐行閱讀本頁" } },
    { "Escape / Command+W", { "Close this page", "ปิดหน้านี้", "このページを閉じる", "关闭本页", "關閉本頁" } },

    { nullptr, { "Moving around LINE", "ไปยังส่วนต่าง ๆ ของ LINE", "LINE 内の移動", "在 LINE 中移动", "在 LINE 中移動" } },
    { "Control+1", { "Friends tab", "แท็บเพื่อน", "友だちタブ", "好友标签页", "好友分頁" } },
    { "Control+2", { "Chats tab", "แท็บแชท", "トークタブ", "聊天标签页", "聊天分頁" } },
    { "Control+3", { "Add friends tab", "แท็บเพิ่มเพื่อน", "友だち追加タブ", "添加好友标签页", "加入好友分頁" } },
    { "Control+C", { "Chat list (switches to the Chats tab first if needed)", "ไปที่รายการแชท (สลับไปแท็บแชทก่อนถ้าจำเป็น)", "トークリストへ (必要ならトークタブに切り替え)", "转到聊天列表 (必要时先切换到聊天标签页)", "前往聊天列表 (必要時先切換到聊天分頁)" } },
    { "Control+L", { "Chat list or friend list", "ไปที่รายการแชทหรือรายชื่อเพื่อน", "トークリストまたは友だちリストへ", "转到聊天列表或好友列表", "前往聊天列表或好友列表" } },
    { "Control+F", { "Search field of the list", "ไปที่ช่องค้นหาของรายการ", "リストの検索欄へ", "转到列表的搜索框", "前往列表的搜尋欄" } },
    { "Control+M", { "Messages of the open chat, starting at the newest", "ไปที่ข้อความของแชทที่เปิดอยู่ เริ่มที่ข้อความล่าสุด", "開いているトークのメッセージへ (最新から)", "转到当前聊天的消息 (从最新开始)", "前往目前聊天的訊息 (從最新開始)" } },
    { "Control+I", { "Message input", "ไปที่ช่องพิมพ์ข้อความ", "メッセージ入力欄へ", "转到消息输入框", "前往訊息輸入框" } },
    { "Control+Shift+1 ... 9", { "Read a recent message without moving (1 is the newest)", "อ่านข้อความล่าสุดโดยไม่ย้ายตำแหน่ง (1 คือใหม่สุด)", "移動せずに最近のメッセージを読む (1 が最新)", "不移动位置朗读最近的消息 (1 为最新)", "不移動位置朗讀最近的訊息 (1 為最新)" } },
    { "Option+Command", { "Works like Control for 1, 2, 3, C, L, F, M and I", "ใช้แทน Control ได้กับ 1, 2, 3, C, L, F, M และ I", "1、2、3、C、L、F、M、I では Control と同じ", "对 1、2、3、C、L、F、M、I 与 Control 相同", "對 1、2、3、C、L、F、M、I 與 Control 相同" } },

    { nullptr, { "Chat list and friend list", "รายการแชทและรายชื่อเพื่อน", "トークリストと友だちリスト", "聊天列表和好友列表", "聊天列表和好友列表" } },
    { "Up / Down / Page Up / Page Down / Home / End", { "Move without opening a chat", "เลื่อนโดยไม่เปิดแชท", "トークを開かずに移動", "移动而不打开聊天", "移動而不開啟聊天" } },
    { "Return / Space", { "Open the chat and go to its message input", "เปิดแชทและไปที่ช่องพิมพ์ข้อความ", "トークを開いてメッセージ入力欄へ", "打开聊天并转到消息输入框", "開啟聊天並前往訊息輸入框" } },
    { "Shift+Return", { "Open the chat in its own window", "เปิดแชทในหน้าต่างแยก", "トークを別ウィンドウで開く", "在单独的窗口中打开聊天", "在獨立視窗中開啟聊天" } },
    { "VO+Shift+M / Shift+F10", { "Menu of the chat", "เปิดเมนูของแชท", "トークのメニュー", "聊天的菜单", "聊天的選單" } },

    { nullptr, { "Messages", "ข้อความ", "メッセージ", "消息", "訊息" } },
    { "Up / Down", { "Previous / next message; Up on the oldest loads older ones", "ข้อความก่อนหน้า / ถัดไป กดขึ้นที่ข้อความเก่าสุดจะโหลดข้อความเก่ากว่า", "前 / 次のメッセージ (最も古いメッセージで上を押すと、さらに古いものを読み込む)", "上一条 / 下一条消息 (在最早的消息上按上键会加载更早的消息)", "上一則 / 下一則訊息 (在最早的訊息上按上鍵會載入更早的訊息)" } },
    { "VO+Left", { "Above the oldest message: loads older ones", "เมื่อเลื่อนขึ้นเลยข้อความเก่าสุด จะโหลดข้อความเก่ากว่า", "最も古いメッセージより上へ移動すると、さらに古いものを読み込む", "移到最早的消息之上时加载更早的消息", "移到最早的訊息之上時載入更早的訊息" } },
    { "Page Up / Page Down", { "About a screen back / forward", "เลื่อนไปประมาณหนึ่งหน้าจอ", "約 1 画面分移動", "移动约一屏", "移動約一個畫面" } },
    { "Home / Command+Up", { "Oldest loaded message", "ข้อความเก่าสุดที่โหลดแล้ว", "読み込み済みの最も古いメッセージ", "已加载的最早消息", "已載入的最早訊息" } },
    { "End / Command+Down", { "Newest message", "ข้อความล่าสุด", "最新のメッセージ", "最新消息", "最新訊息" } },
    { "Return / Space", { "Open \"See more\", a link, a voice message, photo, video or file; play a sound sticker", "เปิด \"ดูเพิ่มเติม\" ลิงก์ ข้อความเสียง รูป วิดีโอ หรือไฟล์ และเล่นเสียงสติกเกอร์", "「もっと見る」、リンク、ボイスメッセージ、写真、動画、ファイルを開く。サウンドスタンプを再生", "打开“查看更多”、链接、语音消息、照片、视频或文件；播放有声贴图", "開啟「查看更多」、連結、語音訊息、照片、影片或檔案；播放有聲貼圖" } },
    { "Control+R", { "Reply to the message and go to the message input", "ตอบกลับข้อความและไปที่ช่องพิมพ์", "メッセージに返信して入力欄へ", "回复消息并转到输入框", "回覆訊息並前往輸入框" } },
    { "Control+Shift+R", { "Open the reactions of the message", "เปิดการแสดงความรู้สึกของข้อความ", "メッセージのリアクションを開く", "打开消息的回应", "開啟訊息的回應" } },
    { "Control+T", { "Translate the message", "แปลข้อความ", "メッセージを翻訳", "翻译消息", "翻譯訊息" } },
    { "Control+Shift+T", { "Turn a voice message or video into text", "แปลงข้อความเสียงหรือวิดีโอเป็นข้อความ", "ボイスメッセージや動画を文字に起こす", "将语音消息或视频转为文字", "將語音訊息或影片轉為文字" } },
    { "Delete", { "Delete the message (LINE asks to confirm)", "ลบข้อความ (LINE จะถามยืนยัน)", "メッセージを削除 (LINE が確認します)", "删除消息 (LINE 会要求确认)", "刪除訊息 (LINE 會要求確認)" } },
    { "Shift+Delete", { "Unsend the message (LINE asks to confirm)", "ยกเลิกการส่งข้อความ (LINE จะถามยืนยัน)", "メッセージの送信を取り消す (LINE が確認します)", "撤回消息 (LINE 会要求确认)", "收回訊息 (LINE 會要求確認)" } },
    { "Command+S", { "Save the message: media and files with LINE's Save as, text as a .txt file", "บันทึกข้อความ: สื่อและไฟล์ผ่าน Save as ของ LINE ข้อความเป็นไฟล์ .txt", "メッセージを保存: メディアとファイルは LINE の「名前を付けて保存」、テキストは .txt ファイル", "保存消息：媒体和文件使用 LINE 的“另存为”，文字保存为 .txt 文件", "儲存訊息：媒體和檔案使用 LINE 的「另存新檔」，文字儲存為 .txt 檔案" } },
    { "VO+Shift+M / Shift+F10", { "Menu of the message", "เปิดเมนูของข้อความ", "メッセージのメニュー", "消息的菜单", "訊息的選單" } },
    { "Tab / Shift+Tab", { "Between the messages, the reply bar, the message input and its buttons", "ย้ายระหว่างข้อความ แถบตอบกลับ ช่องพิมพ์ และปุ่มต่าง ๆ", "メッセージ、返信バー、入力欄、ボタンの間を移動", "在消息、回复栏、输入框及其按钮之间移动", "在訊息、回覆列、輸入框及其按鈕之間移動" } },

    { nullptr, { "Menus", "เมนู", "メニュー", "菜单", "選單" } },
    { "Up / Down / Home / End", { "Move between the items", "เลื่อนไปยังรายการต่าง ๆ", "項目間を移動", "在菜单项之间移动", "在選單項目之間移動" } },
    { "Return / Space", { "Choose the item", "เลือกรายการ", "項目を選択", "选择菜单项", "選擇選單項目" } },
    { "Right / Left", { "Open a sub-menu / go back", "เปิดเมนูย่อย / ย้อนกลับ", "サブメニューを開く / 戻る", "打开子菜单 / 返回", "開啟子選單 / 返回" } },
    { "Escape", { "Close the menu and return to the row", "ปิดเมนูและกลับไปที่แถวเดิม", "メニューを閉じて元の行に戻る", "关闭菜单并返回该行", "關閉選單並返回該列" } },

    { nullptr, { "Reactions", "การแสดงความรู้สึก", "リアクション", "回应", "回應" } },
    { "Left / Right", { "Move between the reactions", "เลื่อนไปยังความรู้สึกต่าง ๆ", "リアクション間を移動", "在回应之间移动", "在回應之間移動" } },
    { "Return / Space", { "Give the reaction", "แสดงความรู้สึกนี้", "このリアクションを送る", "发送此回应", "送出此回應" } },
    { "Escape", { "Close the reactions", "ปิดการแสดงความรู้สึก", "リアクションを閉じる", "关闭回应", "關閉回應" } },

    { nullptr, { "Message input", "ช่องพิมพ์ข้อความ", "メッセージ入力欄", "消息输入框", "訊息輸入框" } },
    { "Up / Down", { "After typing @ in a group: move between the suggested members", "หลังพิมพ์ @ ในกลุ่ม: เลื่อนไปยังสมาชิกที่ LINE แนะนำ", "グループで @ を入力した後: 候補のメンバー間を移動", "在群组中输入 @ 后：在建议的成员之间移动", "在群組中輸入 @ 後：在建議的成員之間移動" } },
    { "Return", { "After typing @ in a group: choose the member", "หลังพิมพ์ @ ในกลุ่ม: เลือกสมาชิก", "グループで @ を入力した後: メンバーを選択", "在群组中输入 @ 后：选择成员", "在群組中輸入 @ 後：選擇成員" } },

    { nullptr, { "Stickers", "สติกเกอร์", "スタンプ", "贴图", "貼圖" } },
    { "Arrows", { "Move between the stickers", "เลื่อนไปยังสติกเกอร์ต่าง ๆ", "スタンプ間を移動", "在贴图之间移动", "在貼圖之間移動" } },
    { "Return / Space", { "First press: preview with its sound. Second press: send", "กดครั้งแรก: ดูตัวอย่างพร้อมเสียง กดครั้งที่สอง: ส่ง", "1 回目: サウンド付きでプレビュー。2 回目: 送信", "第一次：预览并播放声音。第二次：发送", "第一次：預覽並播放聲音。第二次：傳送" } },

    { nullptr, { "Photos & videos, Links and Files", "รูปและวิดีโอ ลิงก์ และไฟล์", "写真・動画、リンク、ファイル", "照片和视频、链接及文件", "照片和影片、連結及檔案" } },
    { "Arrows / Page Up / Page Down / Home / End", { "Move through the grid", "เลื่อนในตาราง", "グリッド内を移動", "在网格中移动", "在格狀畫面中移動" } },
    { "Return", { "Open the item", "เปิดรายการ", "項目を開く", "打开项目", "開啟項目" } },
    { "Space", { "Photos & videos: select or unselect the item; Tab reaches Share, Download and Cancel", "รูปและวิดีโอ: เลือกหรือยกเลิกการเลือก กด Tab เพื่อไปที่แชร์ ดาวน์โหลด และยกเลิก", "写真・動画: 項目を選択 / 解除。Tab で共有、ダウンロード、キャンセルへ", "照片和视频：选择或取消选择；按 Tab 转到分享、下载和取消", "照片和影片：選取或取消選取；按 Tab 前往分享、下載和取消" } },
    { "Control+Shift+T", { "Turn a video into text", "แปลงวิดีโอเป็นข้อความ", "動画を文字に起こす", "将视频转为文字", "將影片轉為文字" } },
    { "VO+Shift+M / Shift+F10", { "Menu of the item", "เปิดเมนูของรายการ", "項目のメニュー", "项目的菜单", "項目的選單" } },

    { nullptr, { "Photo and video viewer", "หน้าดูรูปและวิดีโอ", "写真・動画ビューア", "照片和视频查看器", "照片和影片檢視器" } },
    { "Command+S", { "Save the photo or video", "บันทึกรูปหรือวิดีโอ", "写真や動画を保存", "保存照片或视频", "儲存照片或影片" } },
    { "Control+Shift+T", { "Turn the video into text", "แปลงวิดีโอเป็นข้อความ", "動画を文字に起こす", "将视频转为文字", "將影片轉為文字" } },
    { "Tab", { "Between Play, Position and Playback speed", "ย้ายระหว่างเล่น ตำแหน่ง และความเร็ว", "再生、再生位置、再生速度の間を移動", "在播放、位置和播放速度之间移动", "在播放、位置和播放速度之間移動" } },
    { "Return / Space", { "Play or pause", "เล่นหรือหยุดชั่วคราว", "再生 / 一時停止", "播放或暂停", "播放或暫停" } },
    { "Left / Right", { "On Position: back / forward 5 seconds", "ที่ตำแหน่ง: ย้อน / ไปข้างหน้า 5 วินาที", "再生位置で: 5 秒戻る / 進む", "在位置上：后退 / 前进 5 秒", "在位置上：倒退 / 前進 5 秒" } },
    { "Page Up / Page Down", { "On Position: 30 seconds", "ที่ตำแหน่ง: 30 วินาที", "再生位置で: 30 秒", "在位置上：30 秒", "在位置上：30 秒" } },
    { "Home / End", { "On Position: start / end", "ที่ตำแหน่ง: จุดเริ่มต้น / จุดสิ้นสุด", "再生位置で: 先頭 / 末尾", "在位置上：开头 / 结尾", "在位置上：開頭 / 結尾" } },
    { "Up / Down", { "On Playback speed: faster / slower", "ที่ความเร็ว: เร็วขึ้น / ช้าลง", "再生速度で: 速く / 遅く", "在播放速度上：加快 / 减慢", "在播放速度上：加快 / 減慢" } },

    { nullptr, { "Search in a chat", "ค้นหาในแชท", "トーク内検索", "在聊天中搜索", "在聊天中搜尋" } },
    { "Return", { "Search", "ค้นหา", "検索", "搜索", "搜尋" } },
    { "Up / Down", { "Older / newer result", "ผลลัพธ์ที่เก่ากว่า / ใหม่กว่า", "古い / 新しい検索結果", "更早 / 更新的结果", "更早 / 更新的結果" } },

    { nullptr, { "Converting to text", "การแปลงเสียงเป็นข้อความ", "文字起こし", "转为文字", "轉為文字" } },
    { "Return", { "Start converting", "เริ่มแปลง", "変換を開始", "开始转换", "開始轉換" } },
    { "Escape", { "Cancel or close the window", "ยกเลิกหรือปิดหน้าต่าง", "キャンセル、またはウィンドウを閉じる", "取消或关闭窗口", "取消或關閉視窗" } },

    { nullptr, { "Calls", "การโทร", "通話", "通话", "通話" } },
    { "Control+A", { "Answer an incoming call", "รับสาย", "着信に応答", "接听来电", "接聽來電" } },
    { "Control+D", { "Decline a call, or end the current one", "ปฏิเสธสาย หรือวางสายที่กำลังคุย", "着信を拒否、または通話を終了", "拒接来电或结束当前通话", "拒接來電或結束目前通話" } },
    { "Control+Shift+A / Control+Shift+D", { "From any app, while a LINE call rings: answer / decline", "จากโปรแกรมอื่น ขณะมีสาย LINE เรียกเข้า: รับสาย / ปฏิเสธสาย", "他のアプリから、LINE の着信中に: 応答 / 拒否", "在其他应用中，LINE 来电时：接听 / 拒接", "在其他應用程式中，LINE 來電時：接聽 / 拒接" } },
};

Texts kTitle = { "LINE MR keyboard help", "รายการแป้นพิมพ์ของ LINE MR", "LINE MR キーボードヘルプ", "LINE MR 键盘帮助", "LINE MR 鍵盤說明" };
Texts kClose = { "Close", "ปิด", "閉じる", "关闭", "關閉" };

QString inLanguage(Texts &texts)
{
    return QString::fromUtf8(texts[static_cast<int>(uiLanguage())]);
}

QString helpText()
{
    QStringList lines;
    for (const Row &row : kRows) {
        if (!row.keys) {
            if (!lines.isEmpty())
                lines << QString();
            lines << inLanguage(row.text);
        } else {
            lines << QString::fromUtf8(row.keys) + QStringLiteral(": ") + inLanguage(row.text);
        }
    }
    return lines.join(QLatin1Char('\n'));
}

QPointer<QWidget> g_window;

} // namespace

void showKeyboardHelp()
{
    if (g_window) {
        g_window->raise();
        g_window->activateWindow();
        return;
    }
    QPointer<QWidget> previous = QApplication::activeWindow();
    auto *window = new QWidget(nullptr, Qt::Window);
    window->setObjectName(QLatin1String(kWindowName));
    window->setAttribute(Qt::WA_DeleteOnClose);
    window->setWindowTitle(inLanguage(kTitle));
    window->setAccessibleName(inLanguage(kTitle));
    window->resize(620, 640);
    auto *text = new QPlainTextEdit(window);
    text->setObjectName(QLatin1String(kTextName));
    text->setAccessibleName(inLanguage(kTitle));
    text->setReadOnly(true);
    text->setTextInteractionFlags(Qt::TextSelectableByKeyboard | Qt::TextSelectableByMouse);
    text->setTabChangesFocus(true);
    text->setPlainText(helpText());
    auto *close = new QPushButton(inLanguage(kClose), window);
    QObject::connect(close, &QPushButton::clicked, window, &QWidget::close);
    auto *layout = new QVBoxLayout(window);
    layout->addWidget(text);
    layout->addWidget(close, 0, Qt::AlignRight);
    g_window = window;
    // Back to where the user was, with its focus.
    QObject::connect(window, &QObject::destroyed, qApp, [previous] {
        if (previous && previous->isVisible())
            previous->activateWindow();
    });
    window->show();
    window->raise();
    window->activateWindow();
    text->setFocus(Qt::OtherFocusReason);
}

bool isKeyboardHelp(const QWidget *w)
{
    return w && w->window()->objectName() == QLatin1StringView(kWindowName);
}

bool handleKeyboardHelpKey(QWidget *w, QKeyEvent *key)
{
    if (!isKeyboardHelp(w))
        return false;
    if (key->key() == Qt::Key_Escape
        || (key->key() == Qt::Key_W && (key->modifiers() & Qt::ControlModifier))) {
        w->window()->close();
        return true;
    }
    // LINE's application event filters take the arrows: the text view gets its keys directly.
    if (w->objectName() == QLatin1StringView(kTextName) && key->key() != Qt::Key_Tab && key->key() != Qt::Key_Backtab) {
        static_cast<QObject *>(w)->event(key);
        return true;
    }
    return false;
}

} // namespace line_a11y
