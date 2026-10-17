import Foundation

/// 轻量本地化入口。资源在 App/Resources/{en,zh-Hans}.lproj。
enum L10n {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
        return String(format: format, locale: Locale.current, arguments: args)
    }
}
