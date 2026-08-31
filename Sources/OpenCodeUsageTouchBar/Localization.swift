import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .system: return "System Default"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        }
    }

    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh-hant") || preferred.hasPrefix("zh-tw") ||
            preferred.hasPrefix("zh-hk") || preferred.hasPrefix("zh-mo") {
            return .zhHant
        }
        if preferred.hasPrefix("zh") { return .zhHans }
        if preferred.hasPrefix("ja") { return .japanese }
        if preferred.hasPrefix("ko") { return .korean }
        if preferred.hasPrefix("es") { return .spanish }
        return .english
    }

    var locale: Locale {
        switch resolved {
        case .zhHans: return Locale(identifier: "zh_CN")
        case .zhHant: return Locale(identifier: "zh_TW")
        case .japanese: return Locale(identifier: "ja_JP")
        case .korean: return Locale(identifier: "ko_KR")
        case .spanish: return Locale(identifier: "es_ES")
        case .system, .english: return Locale(identifier: "en_US")
        }
    }
}

enum L10n {
    static func string(_ key: String, language: AppLanguage) -> String {
        let resolved = language.resolved
        return tables[resolved]?[key] ?? tables[.english]?[key] ?? key
    }

    static func format(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        String(format: string(key, language: language), locale: language.locale, arguments: arguments)
    }

    private static let tables: [AppLanguage: [String: String]] = [
        .zhHans: [
            "system_default": "跟随系统", "settings": "设置", "quit": "退出",
            "loading_account": "正在读取账户…", "five_hour_quota": "5 小时额度", "weekly_quota": "每周额度",
            "remaining": "%d%% 剩余", "unavailable": "不可用", "reset_at": "重置：%@", "updated_at": "更新于 %@",
            "credits_unlimited": "积分无限", "credits_balance": "积分 %@", "credits_unavailable": "无积分信息",
            "reset_count": "%d 次重置", "refresh": "刷新", "official_usage": "官方 Usage",
            "section_language": "语言", "language": "应用语言", "section_menu_bar": "菜单栏", "icon": "图标",
            "icon_size": "图标大小", "text_size": "文字字号", "section_general": "通用",
            "launch_at_login": "登录时自动启动",
            "touch_bar_mode": "Touch Bar 模式", "touch_bar_mode_always": "始终显示", "touch_bar_mode_codex": "仅 Codex 前台时显示", "touch_bar_mode_disabled": "不显示", "hide_usage": "隐藏用量", "touch_bar_show": "显示 Touch Bar", "no_usage_source": "未检测到用量来源",
            "touch_bar_description": "常驻显示额度、进度和重置时间；期间会替代前台应用的 Touch Bar 控件，Control Strip 保持可用。",
            "touch_bar_unavailable": "当前系统不支持前台常驻；本应用激活时仍可显示。",
            "settings_window_title": "OpenCode Usage TouchBar 设置", "five_hour_short": "5 小时", "weekly_short": "每周",
            "weekly_prefix": "周", "loading_reset": "正在读取重置时间…", "reset_customization": "Codex 重置时间",
            "refresh_usage": "刷新 Usage", "refresh_codex_usage": "刷新 Codex Usage", "quota_customization": "Codex %@额度",
            "touch_bar_reset": "重置 5h %@ · 周 %@", "loading_usage": "正在读取 Usage…", "usage_unavailable": "Usage 暂不可用",
            "go_title": "OpenCode Go", "go_rolling_quota": "5 小时额度", "go_weekly_quota": "每周额度",
            "go_monthly_quota": "每月额度", "monthly_prefix": "月", "go_reset_customization": "OpenCode Go 重置时间",
            "go_quota_customization": "OpenCode Go %@额度", "go_touch_bar_reset": "Go 重置 5h %@ · 周 %@ · 月 %@",
            "opencode_go_key_placeholder": "OpenCode Go API 密钥", "opencode_go_key_save": "保存密钥", "opencode_go_key_remove": "移除密钥",
            "opencode_go_key_stored": "API 密钥已存入钥匙串。", "opencode_go_key_not_stored": "钥匙串中没有 API 密钥。",
            "error_opencode_go_key_missing": "OpenCode Go 未配置。请在设置中添加 API 密钥，或使用已导出 OPENCODE_GO_API_KEY 的终端启动应用。",
            "error_opencode_go_key_save": "无法保存 OpenCode Go API 密钥：%@",
            "error_opencode_go_invalid_credentials": "OpenCode Go API 密钥无效或已过期。",
            "error_opencode_go_invalid_response": "OpenCode Go 返回了无法识别的用量数据。",
            "error_opencode_go_server": "OpenCode Go 返回错误：%@",
            "error_codex_not_found": "找不到 Codex CLI。请先安装或更新 ChatGPT/Codex。",
            "error_launch_failed": "无法启动 Codex：%@", "error_timeout": "读取超时，请稍后重试。",
            "error_invalid_response": "Codex 返回了无法识别的 Usage 数据。", "error_server": "Codex 返回错误：%@",
            "error_unknown": "未知错误", "error_launch_at_login": "无法更新开机启动设置：%@",
            "icon_gauge": "仪表盘", "icon_simple_gauge": "简洁仪表", "icon_speedometer": "速度表", "icon_bar_chart": "柱状图",
            "icon_trend": "趋势图", "icon_percent": "百分比", "icon_bolt": "闪电", "icon_flame": "火焰",
            "icon_sparkles": "星光", "icon_terminal": "终端", "icon_command": "Command", "icon_cpu": "处理器",
            "icon_chip": "芯片", "icon_timer": "计时器", "icon_refresh_clock": "刷新时钟", "icon_waveform": "状态波形", "icon_hidden": "隐藏图标"
        ],
        .zhHant: [
            "system_default": "跟隨系統", "settings": "設定", "quit": "結束",
            "loading_account": "正在讀取帳戶…", "five_hour_quota": "5 小時額度", "weekly_quota": "每週額度",
            "remaining": "剩餘 %d%%", "unavailable": "無法使用", "reset_at": "重置：%@", "updated_at": "更新於 %@",
            "credits_unlimited": "點數無限", "credits_balance": "點數 %@", "credits_unavailable": "無點數資訊",
            "reset_count": "%d 次重置", "refresh": "重新整理", "official_usage": "官方 Usage",
            "section_language": "語言", "language": "應用程式語言", "section_menu_bar": "選單列", "icon": "圖示",
            "icon_size": "圖示大小", "text_size": "文字大小", "section_general": "一般",
            "launch_at_login": "登入時自動啟動",
            "touch_bar_mode": "Touch Bar 模式", "touch_bar_mode_always": "始終顯示", "touch_bar_mode_codex": "僅 Codex 在前景時顯示", "touch_bar_mode_disabled": "不顯示", "hide_usage": "隱藏用量", "touch_bar_show": "顯示 Touch Bar", "no_usage_source": "未偵測到用量來源",
            "touch_bar_description": "常駐顯示額度、進度與重置時間；期間會取代前景應用的 Touch Bar 控件，Control Strip 保持可用。",
            "touch_bar_unavailable": "目前系統不支援前景常駐；啟用本應用程式時仍可顯示。",
            "settings_window_title": "OpenCode Usage TouchBar 設定", "five_hour_short": "5 小時", "weekly_short": "每週",
            "weekly_prefix": "週", "loading_reset": "正在讀取重置時間…", "reset_customization": "Codex 重置時間",
            "refresh_usage": "重新整理 Usage", "refresh_codex_usage": "重新整理 Codex Usage", "quota_customization": "Codex %@額度",
            "touch_bar_reset": "重置 5h %@ · 週 %@", "loading_usage": "正在讀取 Usage…", "usage_unavailable": "Usage 暫時無法使用",
            "go_title": "OpenCode Go", "go_rolling_quota": "5 小時額度", "go_weekly_quota": "每週額度",
            "go_monthly_quota": "每月額度", "monthly_prefix": "月", "go_reset_customization": "OpenCode Go 重置時間",
            "go_quota_customization": "OpenCode Go %@額度", "go_touch_bar_reset": "Go 重置 5h %@ · 週 %@ · 月 %@",
            "opencode_go_key_placeholder": "OpenCode Go API 金鑰", "opencode_go_key_save": "儲存金鑰", "opencode_go_key_remove": "移除金鑰",
            "opencode_go_key_stored": "API 金鑰已存入鑰匙圈。", "opencode_go_key_not_stored": "鑰匙圈中沒有 API 金鑰。",
            "error_opencode_go_key_missing": "OpenCode Go 未設定。請在設定中加入 API 金鑰，或使用已匯出 OPENCODE_GO_API_KEY 的終端機啟動應用程式。",
            "error_opencode_go_key_save": "無法儲存 OpenCode Go API 金鑰：%@",
            "error_opencode_go_invalid_credentials": "OpenCode Go API 金鑰無效或已過期。",
            "error_opencode_go_invalid_response": "OpenCode Go 傳回了無法辨識的用量資料。",
            "error_opencode_go_server": "OpenCode Go 傳回錯誤：%@",
            "error_codex_not_found": "找不到 Codex CLI。請先安裝或更新 ChatGPT/Codex。",
            "error_launch_failed": "無法啟動 Codex：%@", "error_timeout": "讀取逾時，請稍後再試。",
            "error_invalid_response": "Codex 傳回了無法識別的 Usage 資料。", "error_server": "Codex 傳回錯誤：%@",
            "error_unknown": "未知錯誤", "error_launch_at_login": "無法更新登入啟動設定：%@",
            "icon_gauge": "儀表板", "icon_simple_gauge": "簡潔儀表", "icon_speedometer": "速度表", "icon_bar_chart": "長條圖",
            "icon_trend": "趨勢圖", "icon_percent": "百分比", "icon_bolt": "閃電", "icon_flame": "火焰",
            "icon_sparkles": "星光", "icon_terminal": "終端機", "icon_command": "Command", "icon_cpu": "處理器",
            "icon_chip": "晶片", "icon_timer": "計時器", "icon_refresh_clock": "更新時鐘", "icon_waveform": "狀態波形", "icon_hidden": "隱藏圖示"
        ],
        .english: [
            "system_default": "System Default", "settings": "Settings", "quit": "Quit",
            "loading_account": "Loading account…", "five_hour_quota": "5-hour limit", "weekly_quota": "Weekly limit",
            "remaining": "%d%% remaining", "unavailable": "Unavailable", "reset_at": "Resets: %@", "updated_at": "Updated %@",
            "credits_unlimited": "Unlimited credits", "credits_balance": "Credits %@", "credits_unavailable": "No credit information",
            "reset_count": "%d resets", "refresh": "Refresh", "official_usage": "Official Usage",
            "section_language": "Language", "language": "App language", "section_menu_bar": "Menu Bar", "icon": "Icon",
            "icon_size": "Icon size", "text_size": "Text size", "section_general": "General",
            "launch_at_login": "Launch at login",
            "touch_bar_mode": "Touch Bar mode", "touch_bar_mode_always": "Always visible", "touch_bar_mode_codex": "Only while Codex is active", "touch_bar_mode_disabled": "Disabled", "hide_usage": "Hide usage", "touch_bar_show": "Show Touch Bar", "no_usage_source": "No usage source detected",
            "touch_bar_description": "Keeps limits, progress, and reset times visible; replaces contextual app controls while active. The Control Strip stays available.",
            "touch_bar_unavailable": "Persistent display is unavailable on this system; it can still appear while this app is active.",
            "settings_window_title": "OpenCode Usage TouchBar Settings", "five_hour_short": "5 hour", "weekly_short": "Weekly",
            "weekly_prefix": "Wk", "loading_reset": "Loading reset times…", "reset_customization": "Codex reset times",
            "refresh_usage": "Refresh Usage", "refresh_codex_usage": "Refresh Codex Usage", "quota_customization": "Codex %@ limit",
            "touch_bar_reset": "Reset 5h %@ · Wk %@", "loading_usage": "Loading Usage…", "usage_unavailable": "Usage unavailable",
            "go_title": "OpenCode Go", "go_rolling_quota": "5-hour limit", "go_weekly_quota": "Weekly limit",
            "go_monthly_quota": "Monthly limit", "monthly_prefix": "Mo", "go_reset_customization": "OpenCode Go reset times",
            "go_quota_customization": "OpenCode Go %@ limit", "go_touch_bar_reset": "Go reset 5h %@ · Wk %@ · Mo %@",
            "opencode_go_key_placeholder": "OpenCode Go API key", "opencode_go_key_save": "Save Key", "opencode_go_key_remove": "Remove Key",
            "opencode_go_key_stored": "API key stored in Keychain.", "opencode_go_key_not_stored": "No API key stored in Keychain.",
            "error_opencode_go_key_missing": "OpenCode Go is not configured. Add your API key in Settings, or launch the app with OPENCODE_GO_API_KEY exported.",
            "error_opencode_go_key_save": "Could not save the OpenCode Go API key: %@",
            "error_opencode_go_invalid_credentials": "OpenCode Go API key is invalid or expired.",
            "error_opencode_go_invalid_response": "OpenCode Go returned unrecognized usage data.",
            "error_opencode_go_server": "OpenCode Go returned an error: %@",
            "error_codex_not_found": "Codex CLI was not found. Install or update ChatGPT/Codex first.",
            "error_launch_failed": "Could not start Codex: %@", "error_timeout": "The request timed out. Try again later.",
            "error_invalid_response": "Codex returned unrecognized Usage data.", "error_server": "Codex returned an error: %@",
            "error_unknown": "Unknown error", "error_launch_at_login": "Could not update the launch-at-login setting: %@",
            "icon_gauge": "Gauge", "icon_simple_gauge": "Simple Gauge", "icon_speedometer": "Speedometer", "icon_bar_chart": "Bar Chart",
            "icon_trend": "Trend", "icon_percent": "Percentage", "icon_bolt": "Bolt", "icon_flame": "Flame",
            "icon_sparkles": "Sparkles", "icon_terminal": "Terminal", "icon_command": "Command", "icon_cpu": "Processor",
            "icon_chip": "Chip", "icon_timer": "Timer", "icon_refresh_clock": "Refresh Clock", "icon_waveform": "Status Waveform", "icon_hidden": "Hide Icon"
        ],
        .japanese: [
            "system_default": "システム設定に従う", "settings": "設定", "quit": "終了",
            "loading_account": "アカウントを読み込み中…", "five_hour_quota": "5時間の上限", "weekly_quota": "週間上限",
            "remaining": "残り %d%%", "unavailable": "利用不可", "reset_at": "リセット：%@", "updated_at": "更新：%@",
            "credits_unlimited": "クレジット無制限", "credits_balance": "クレジット %@", "credits_unavailable": "クレジット情報なし",
            "reset_count": "%d 回リセット", "refresh": "更新", "official_usage": "公式 Usage",
            "section_language": "言語", "language": "アプリの言語", "section_menu_bar": "メニューバー", "icon": "アイコン",
            "icon_size": "アイコンサイズ", "text_size": "文字サイズ", "section_general": "一般",
            "launch_at_login": "ログイン時に起動",
            "touch_bar_mode": "Touch Bar モード", "touch_bar_mode_always": "常時表示", "touch_bar_mode_codex": "Codex 前面時のみ表示", "touch_bar_mode_disabled": "表示しない", "hide_usage": "用量を非表示", "touch_bar_show": "Touch Bar を表示", "no_usage_source": "用量ソースが見つかりません",
            "touch_bar_description": "上限・進捗・リセット時刻を常時表示します。有効間はアプリの Touch Bar コントロールを置き換え、Control Strip は使用できます。",
            "touch_bar_unavailable": "このシステムでは常時表示できませんが、本アプリの使用中は表示できます。",
            "settings_window_title": "OpenCode Usage TouchBar 設定", "five_hour_short": "5時間", "weekly_short": "週間",
            "weekly_prefix": "週", "loading_reset": "リセット時刻を読み込み中…", "reset_customization": "Codex リセット時刻",
            "refresh_usage": "Usage を更新", "refresh_codex_usage": "Codex Usage を更新", "quota_customization": "Codex %@上限",
            "touch_bar_reset": "リセット 5h %@・週 %@", "loading_usage": "Usage を読み込み中…", "usage_unavailable": "Usage を利用できません",
            "go_title": "OpenCode Go", "go_rolling_quota": "5時間の上限", "go_weekly_quota": "週間上限",
            "go_monthly_quota": "月間上限", "monthly_prefix": "月", "go_reset_customization": "OpenCode Go リセット時刻",
            "go_quota_customization": "OpenCode Go %@上限", "go_touch_bar_reset": "Go リセット 5h %@・週 %@・月 %@",
            "opencode_go_key_placeholder": "OpenCode Go API キー", "opencode_go_key_save": "キーを保存", "opencode_go_key_remove": "キーを削除",
            "opencode_go_key_stored": "API キーはキーチェーンに保存されています。", "opencode_go_key_not_stored": "キーチェーンに API キーはありません。",
            "error_opencode_go_key_missing": "OpenCode Go が設定されていません。設定で API キーを追加するか、OPENCODE_GO_API_KEY をエクスポートした状態で起動してください。",
            "error_opencode_go_key_save": "OpenCode Go API キーを保存できません：%@",
            "error_opencode_go_invalid_credentials": "OpenCode Go API キーが無効または期限切れです。",
            "error_opencode_go_invalid_response": "OpenCode Go から認識できない使用量データが返されました。",
            "error_opencode_go_server": "OpenCode Go エラー：%@",
            "error_codex_not_found": "Codex CLI が見つかりません。ChatGPT/Codex をインストールまたは更新してください。",
            "error_launch_failed": "Codex を起動できません：%@", "error_timeout": "読み込みがタイムアウトしました。後でもう一度お試しください。",
            "error_invalid_response": "Codex から認識できない Usage データが返されました。", "error_server": "Codex エラー：%@",
            "error_unknown": "不明なエラー", "error_launch_at_login": "ログイン時起動の設定を更新できません：%@",
            "icon_gauge": "ゲージ", "icon_simple_gauge": "シンプルゲージ", "icon_speedometer": "速度計", "icon_bar_chart": "棒グラフ",
            "icon_trend": "トレンド", "icon_percent": "パーセント", "icon_bolt": "稲妻", "icon_flame": "炎",
            "icon_sparkles": "きらめき", "icon_terminal": "ターミナル", "icon_command": "Command", "icon_cpu": "プロセッサ",
            "icon_chip": "チップ", "icon_timer": "タイマー", "icon_refresh_clock": "更新時計", "icon_waveform": "ステータス波形", "icon_hidden": "アイコンを非表示"
        ],
        .korean: [
            "system_default": "시스템 설정 따르기", "settings": "설정", "quit": "종료",
            "loading_account": "계정 불러오는 중…", "five_hour_quota": "5시간 한도", "weekly_quota": "주간 한도",
            "remaining": "%d%% 남음", "unavailable": "사용할 수 없음", "reset_at": "재설정: %@", "updated_at": "업데이트: %@",
            "credits_unlimited": "크레딧 무제한", "credits_balance": "크레딧 %@", "credits_unavailable": "크레딧 정보 없음",
            "reset_count": "%d회 재설정", "refresh": "새로 고침", "official_usage": "공식 Usage",
            "section_language": "언어", "language": "앱 언어", "section_menu_bar": "메뉴 막대", "icon": "아이콘",
            "icon_size": "아이콘 크기", "text_size": "텍스트 크기", "section_general": "일반",
            "launch_at_login": "로그인 시 실행",
            "touch_bar_mode": "Touch Bar 모드", "touch_bar_mode_always": "항상 표시", "touch_bar_mode_codex": "Codex 활성 시에만 표시", "touch_bar_mode_disabled": "표시 안 함", "hide_usage": "사용량 숨기기", "touch_bar_show": "Touch Bar 표시", "no_usage_source": "사용량 소스를 찾을 수 없음",
            "touch_bar_description": "한도, 진행률, 재설정 시간을 항상 표시합니다. 활성 중에 앱의 Touch Bar 컨트롤을 대체하며 Control Strip은 사용할 수 있습니다.",
            "touch_bar_unavailable": "이 시스템에서는 상시 표시할 수 없지만 앱이 활성화된 동안에는 표시됩니다.",
            "settings_window_title": "OpenCode Usage TouchBar 설정", "five_hour_short": "5시간", "weekly_short": "주간",
            "weekly_prefix": "주", "loading_reset": "재설정 시간 불러오는 중…", "reset_customization": "Codex 재설정 시간",
            "refresh_usage": "Usage 새로 고침", "refresh_codex_usage": "Codex Usage 새로 고침", "quota_customization": "Codex %@ 한도",
            "touch_bar_reset": "재설정 5h %@ · 주 %@", "loading_usage": "Usage 불러오는 중…", "usage_unavailable": "Usage 사용 불가",
            "go_title": "OpenCode Go", "go_rolling_quota": "5시간 한도", "go_weekly_quota": "주간 한도",
            "go_monthly_quota": "월간 한도", "monthly_prefix": "월", "go_reset_customization": "OpenCode Go 재설정 시간",
            "go_quota_customization": "OpenCode Go %@ 한도", "go_touch_bar_reset": "Go 재설정 5h %@ · 주 %@ · 월 %@",
            "opencode_go_key_placeholder": "OpenCode Go API 키", "opencode_go_key_save": "키 저장", "opencode_go_key_remove": "키 제거",
            "opencode_go_key_stored": "API 키가 키체인에 저장되었습니다.", "opencode_go_key_not_stored": "키체인에 저장된 API 키가 없습니다.",
            "error_opencode_go_key_missing": "OpenCode Go가 구성되지 않았습니다. 설정에서 API 키를 추가하거나 OPENCODE_GO_API_KEY를 내보낸 상태로 앱을 실행하세요.",
            "error_opencode_go_key_save": "OpenCode Go API 키를 저장할 수 없습니다: %@",
            "error_opencode_go_invalid_credentials": "OpenCode Go API 키가 잘못되었거나 만료되었습니다.",
            "error_opencode_go_invalid_response": "OpenCode Go가 인식할 수 없는 사용량 데이터를 반환했습니다.",
            "error_opencode_go_server": "OpenCode Go 오류: %@",
            "error_codex_not_found": "Codex CLI를 찾을 수 없습니다. ChatGPT/Codex를 설치하거나 업데이트하세요.",
            "error_launch_failed": "Codex를 실행할 수 없습니다: %@", "error_timeout": "요청 시간이 초과되었습니다. 나중에 다시 시도하세요.",
            "error_invalid_response": "Codex가 인식할 수 없는 Usage 데이터를 반환했습니다.", "error_server": "Codex 오류: %@",
            "error_unknown": "알 수 없는 오류", "error_launch_at_login": "로그인 시 실행 설정을 업데이트할 수 없습니다: %@",
            "icon_gauge": "게이지", "icon_simple_gauge": "간단한 게이지", "icon_speedometer": "속도계", "icon_bar_chart": "막대 차트",
            "icon_trend": "추세", "icon_percent": "백분율", "icon_bolt": "번개", "icon_flame": "불꽃",
            "icon_sparkles": "반짝임", "icon_terminal": "터미널", "icon_command": "Command", "icon_cpu": "프로세서",
            "icon_chip": "칩", "icon_timer": "타이머", "icon_refresh_clock": "새로 고침 시계", "icon_waveform": "상태 파형", "icon_hidden": "아이콘 숨기기"
        ],
        .spanish: [
            "system_default": "Según el sistema", "settings": "Ajustes", "quit": "Salir",
            "loading_account": "Cargando cuenta…", "five_hour_quota": "Límite de 5 horas", "weekly_quota": "Límite semanal",
            "remaining": "%d%% restante", "unavailable": "No disponible", "reset_at": "Se restablece: %@", "updated_at": "Actualizado %@",
            "credits_unlimited": "Créditos ilimitados", "credits_balance": "Créditos %@", "credits_unavailable": "Sin información de créditos",
            "reset_count": "%d restablecimientos", "refresh": "Actualizar", "official_usage": "Usage oficial",
            "section_language": "Idioma", "language": "Idioma de la app", "section_menu_bar": "Barra de menús", "icon": "Icono",
            "icon_size": "Tamaño del icono", "text_size": "Tamaño del texto", "section_general": "General",
            "launch_at_login": "Abrir al iniciar sesión",
            "touch_bar_mode": "Modo de la Touch Bar", "touch_bar_mode_always": "Siempre visible", "touch_bar_mode_codex": "Solo con Codex activo", "touch_bar_mode_disabled": "Desactivado", "hide_usage": "Ocultar uso", "touch_bar_show": "Mostrar Touch Bar", "no_usage_source": "No se detectó ninguna fuente de uso",
            "touch_bar_description": "Mantiene visibles límites, progreso y horas de restablecimiento; reemplaza los controles contextuales de la app. El Control Strip sigue disponible.",
            "touch_bar_unavailable": "La visualización permanente no está disponible; puede mostrarse mientras esta app esté activa.",
            "settings_window_title": "Ajustes de OpenCode Usage TouchBar", "five_hour_short": "5 horas", "weekly_short": "Semanal",
            "weekly_prefix": "Sem", "loading_reset": "Cargando restablecimientos…", "reset_customization": "Restablecimientos de Codex",
            "refresh_usage": "Actualizar Usage", "refresh_codex_usage": "Actualizar Codex Usage", "quota_customization": "Límite %@ de Codex",
            "touch_bar_reset": "Rest. 5h %@ · Sem %@", "loading_usage": "Cargando Usage…", "usage_unavailable": "Usage no disponible",
            "go_title": "OpenCode Go", "go_rolling_quota": "Límite de 5 horas", "go_weekly_quota": "Límite semanal",
            "go_monthly_quota": "Límite mensual", "monthly_prefix": "Mes", "go_reset_customization": "Restablecimientos de OpenCode Go",
            "go_quota_customization": "Límite %@ de OpenCode Go", "go_touch_bar_reset": "Go rest. 5h %@ · Sem %@ · Mes %@",
            "opencode_go_key_placeholder": "Clave de API de OpenCode Go", "opencode_go_key_save": "Guardar clave", "opencode_go_key_remove": "Eliminar clave",
            "opencode_go_key_stored": "Clave de API guardada en el Llavero.", "opencode_go_key_not_stored": "No hay ninguna clave de API en el Llavero.",
            "error_opencode_go_key_missing": "OpenCode Go no está configurado. Añade tu clave de API en Ajustes, o abre la app con OPENCODE_GO_API_KEY exportada.",
            "error_opencode_go_key_save": "No se pudo guardar la clave de API de OpenCode Go: %@",
            "error_opencode_go_invalid_credentials": "La clave de API de OpenCode Go no es válida o ha caducado.",
            "error_opencode_go_invalid_response": "OpenCode Go devolvió datos de uso no reconocidos.",
            "error_opencode_go_server": "Error de OpenCode Go: %@",
            "error_codex_not_found": "No se encontró Codex CLI. Instala o actualiza ChatGPT/Codex.",
            "error_launch_failed": "No se pudo iniciar Codex: %@", "error_timeout": "La solicitud agotó el tiempo. Inténtalo más tarde.",
            "error_invalid_response": "Codex devolvió datos de Usage no reconocidos.", "error_server": "Error de Codex: %@",
            "error_unknown": "Error desconocido", "error_launch_at_login": "No se pudo actualizar el inicio de sesión: %@",
            "icon_gauge": "Indicador", "icon_simple_gauge": "Indicador simple", "icon_speedometer": "Velocímetro", "icon_bar_chart": "Gráfico de barras",
            "icon_trend": "Tendencia", "icon_percent": "Porcentaje", "icon_bolt": "Rayo", "icon_flame": "Llama",
            "icon_sparkles": "Destellos", "icon_terminal": "Terminal", "icon_command": "Command", "icon_cpu": "Procesador",
            "icon_chip": "Chip", "icon_timer": "Temporizador", "icon_refresh_clock": "Reloj de actualización", "icon_waveform": "Onda de estado", "icon_hidden": "Ocultar icono"
        ]
    ]
}
