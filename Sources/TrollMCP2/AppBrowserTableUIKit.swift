import SwiftUI
import UIKit

/// v6.0.31：UIKit 原生应用浏览器——TrollStore/TrollFools 同款 UITableView 命令式渲染。
/// 替换 SwiftUI AppBrowserList：cellForRow 每次复用同步设图（免疫 SwiftUI @State 滚动重建、
/// 懒加载、"回划变字母"），图标缓存逻辑（AppCatalog.iconCache/磁盘缓存/warmIcons）不变，
/// 与 UI 框架无关，直接复用。
/// 用法：SwiftUI 内嵌 UIViewControllerRepresentable，数据驱动（apps/runningIds 变化即 rebuild）。
final class AppBrowserTableController: UITableViewController, UISearchBarDelegate {

    var allApps: [AppCatalog.AppEntry] = []
    var runningIds: Set<String> = []
    var onTap: ((AppCatalog.AppEntry) -> Void)?

    private enum Category: Int { case all = 0, user, troll, running }

    private var category: Category = .all
    private var searchText = ""
    private var groups: [(key: String, apps: [AppCatalog.AppEntry])] = []

    private let searchBar = UISearchBar()
    private let searchWrap = UIView()   // 搜索栏圆角容器（视觉对齐原 SwiftUI 版搜索胶囊）
    private let categoryControl = UISegmentedControl(items: ["全部", "用户", "巨魔", "运行中"])
    // v6.1.4：双架构验证——arm64e 切片让 App 原生运行后，系统分享面板实测入口
    private let testShareTextButton = UIButton(type: .system)
    private let testShareFileButton = UIButton(type: .system)
    private let testShareCaption = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(AppBrowserCell.self, forCellReuseIdentifier: AppBrowserCell.reuseID)
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .onDrag
        tableView.sectionIndexColor = .secondaryLabel
        tableView.sectionIndexBackgroundColor = .clear

        searchBar.delegate = self
        searchBar.placeholder = "搜索应用名称或 Bundle ID"
        searchBar.searchBarStyle = .minimal
        searchBar.backgroundImage = UIImage()
        searchBar.searchTextField.font = .systemFont(ofSize: 15)

        searchWrap.backgroundColor = .secondarySystemBackground
        searchWrap.layer.cornerRadius = 12
        searchWrap.clipsToBounds = true

        categoryControl.selectedSegmentIndex = 0
        categoryControl.addTarget(self, action: #selector(categoryChanged(_:)), for: .valueChanged)
        // 加大分段控件字号（原生默认偏小）
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold)
        ]
        categoryControl.setTitleTextAttributes(attrs, for: .normal)
        categoryControl.setTitleTextAttributes(attrs, for: .selected)

        // v6.1.4：双架构验证分享按钮（纯 UIKit 直出）——arm64e 原生运行后若不崩=双架构修复生效
        testShareTextButton.setTitle("测试分享·文本", for: .normal)
        testShareTextButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        testShareTextButton.setTitleColor(.systemTeal, for: .normal)
        testShareTextButton.addTarget(self, action: #selector(testShareText), for: .touchUpInside)
        testShareFileButton.setTitle("测试分享·文件", for: .normal)
        testShareFileButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        testShareFileButton.setTitleColor(.systemOrange, for: .normal)
        testShareFileButton.addTarget(self, action: #selector(testShareFile), for: .touchUpInside)
        testShareCaption.text = "双架构验证：不崩=分享可恢复，闪退=环境限制坐实"
        testShareCaption.font = .systemFont(ofSize: 10)
        testShareCaption.textColor = .tertiaryLabel

        // v6.1.3：header 全部用 Auto Layout 钉住头尾——修复 SwiftUI 托管下按 320pt 占位宽度
        // 排布导致搜索栏/分段控件不满宽的问题；autoresizingFlexibleWidth 让 UITableView 自动跟宽
        let header = makeHeader()
        tableView.tableHeaderView = header
        rebuild()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 双保险：SwiftUI 托管下强制 header 宽度跟随真实屏宽（tableHeaderView 需重新赋值才生效）
        guard let header = tableView.tableHeaderView else { return }
        let w = tableView.bounds.width
        if abs(header.frame.width - w) > 0.5 {
            header.frame.size.width = w
            tableView.tableHeaderView = header
        }
    }

    private func makeHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 4 + 50 + 6 + 40 + 6 + 30 + 6 + 16 + 6))
        header.autoresizingMask = [.flexibleWidth]

        for v in [searchWrap, categoryControl, testShareTextButton, testShareFileButton, testShareCaption] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchWrap.addSubview(searchBar)

        NSLayoutConstraint.activate([
            // 搜索栏：左右 16pt 钉住 header 边缘，随宽度自动拉伸
            searchWrap.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            searchWrap.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            searchWrap.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
            searchWrap.heightAnchor.constraint(equalToConstant: 50),
            searchBar.leadingAnchor.constraint(equalTo: searchWrap.leadingAnchor, constant: 6),
            searchBar.trailingAnchor.constraint(equalTo: searchWrap.trailingAnchor, constant: -6),
            searchBar.topAnchor.constraint(equalTo: searchWrap.topAnchor),
            searchBar.bottomAnchor.constraint(equalTo: searchWrap.bottomAnchor),
            // 分类分段控件：同样左右钉满
            categoryControl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            categoryControl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            categoryControl.topAnchor.constraint(equalTo: searchWrap.bottomAnchor, constant: 6),
            categoryControl.heightAnchor.constraint(equalToConstant: 40),
            // 分享验证按钮（v6.1.4）
            testShareTextButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            testShareTextButton.topAnchor.constraint(equalTo: categoryControl.bottomAnchor, constant: 6),
            testShareTextButton.widthAnchor.constraint(equalToConstant: 118),
            testShareTextButton.heightAnchor.constraint(equalToConstant: 30),
            testShareFileButton.leadingAnchor.constraint(equalTo: testShareTextButton.trailingAnchor, constant: 8),
            testShareFileButton.centerYAnchor.constraint(equalTo: testShareTextButton.centerYAnchor),
            testShareFileButton.widthAnchor.constraint(equalToConstant: 118),
            testShareFileButton.heightAnchor.constraint(equalToConstant: 30),
            testShareCaption.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            testShareCaption.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            testShareCaption.topAnchor.constraint(equalTo: testShareTextButton.bottomAnchor),
            testShareCaption.heightAnchor.constraint(equalToConstant: 16)
        ])
        return header
    }

    // MARK: - 系统分享面板实测（v6.1.4，纯 UIKit UIActivityViewController 直出）
    @objc private func testShareText() {
        let vc = UIActivityViewController(
            activityItems: ["TrollAgent 分享面板测试 \(Date())"],
            applicationActivities: nil)
        presentShareTest(vc)
    }

    @objc private func testShareFile() {
        let path = NSTemporaryDirectory() + "/TrollAgent_share_test.txt"
        try? "TrollAgent 分享面板测试 \(Date())".write(toFile: path, atomically: true, encoding: .utf8)
        let vc = UIActivityViewController(
            activityItems: [URL(fileURLWithPath: path)],
            applicationActivities: nil)
        presentShareTest(vc)
    }

    private func presentShareTest(_ vc: UIActivityViewController) {
        if let pop = vc.popoverPresentationController {
            pop.sourceView = tableView
            pop.sourceRect = tableView.bounds
        }
        present(vc, animated: true, completion: nil)
    }

    /// 数据或筛选变化时重建分组（数据更新由 SwiftUI 包装器调用；筛选由内部控件触发）
    func rebuild() {
        let filtered = computeFiltered()
        // 按首字母分组（A-Z，# 排最后），与旧 SwiftUI 版一致
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var map: [String: [AppCatalog.AppEntry]] = [:]
        for app in filtered {
            let first = app.name.first.map { String($0).uppercased() } ?? "#"
            let key = letters.contains(first) ? first : "#"
            map[key, default: []].append(app)
        }
        let keys = map.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        groups = keys.map { ($0, map[$0]!) }
        tableView.reloadData()
    }

    private func computeFiltered() -> [AppCatalog.AppEntry] {
        var list = allApps
        switch category {
        case .all: break
        case .user: list = allApps.filter { $0.isUser && !$0.isTroll }
        case .troll: list = allApps.filter { $0.isTroll }
        case .running: list = allApps.filter { runningIds.contains(String($0.execName.prefix(16))) }
        }
        if !searchText.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.bundleId.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list
    }

    // MARK: - 筛选控件
    @objc private func categoryChanged(_ sender: UISegmentedControl) {
        category = Category(rawValue: sender.selectedSegmentIndex) ?? .all
        rebuild()
    }

    // MARK: - UISearchBarDelegate
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.searchText = searchText
        rebuild()
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    // MARK: - UITableViewDataSource
    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].apps.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { groups[section].key }
    override func sectionIndexTitles(for tableView: UITableView) -> [String]? { groups.map { $0.key } }
    override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int { index }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AppBrowserCell.reuseID, for: indexPath) as! AppBrowserCell
        let app = groups[indexPath.section].apps[indexPath.row]
        cell.configure(with: app)
        // TrollStore 同款：同步查缓存/系统图标链（内存→磁盘→系统方法→proxy）；
        // miss 先占位，后台文件读取回填缓存后定点重设该行，不整表刷新
        if let img = AppCatalog.icon(for: app) {
            cell.setIcon(img)
        } else {
            cell.setPlaceholder()
            scheduleBackfill(for: app)
        }
        return cell
    }

    private func scheduleBackfill(for app: AppCatalog.AppEntry) {
        for delay in [0.4, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                guard let img = AppCatalog.iconCache.object(forKey: app.bundleId as NSString)
                        ?? AppCatalog.icon(for: app),
                      let ip = self.indexPath(forBundleId: app.bundleId),
                      let cell = self.tableView.cellForRow(at: ip) as? AppBrowserCell else { return }
                cell.setIcon(img)
            }
        }
    }

    private func indexPath(forBundleId bid: String) -> IndexPath? {
        for (s, g) in groups.enumerated() {
            if let r = g.apps.firstIndex(where: { $0.bundleId == bid }) {
                return IndexPath(row: r, section: s)
            }
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onTap?(groups[indexPath.section].apps[indexPath.row])
    }
}

/// SwiftUI 内嵌入口：数据驱动，apps/runningIds 变化即 rebuild
struct AppBrowserTableUIKit: UIViewControllerRepresentable {
    let apps: [AppCatalog.AppEntry]
    let runningIds: Set<String>
    var onTap: (AppCatalog.AppEntry) -> Void

    func makeUIViewController(context: Context) -> AppBrowserTableController {
        let c = AppBrowserTableController(style: .plain)
        c.onTap = onTap
        return c
    }

    func updateUIViewController(_ vc: AppBrowserTableController, context: Context) {
        vc.allApps = apps
        vc.runningIds = runningIds
        vc.onTap = onTap
        vc.rebuild()
    }
}

/// 应用行 cell：42pt 圆角图标 + 名称 + Bundle ID + 版本胶囊 + 类型徽标
final class AppBrowserCell: UITableViewCell {
    static let reuseID = "AppBrowserCell"

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let bundleLabel = UILabel()
    private let versionLabel = PaddedLabel()
    private let badgeLabel = PaddedLabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 10
        iconView.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 16)
        titleLabel.textColor = .label
        bundleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        bundleLabel.textColor = .secondaryLabel

        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabel
        versionLabel.backgroundColor = .tertiarySystemFill
        versionLabel.layer.cornerRadius = 6
        versionLabel.clipsToBounds = true
        versionLabel.textInsets = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)

        badgeLabel.font = .systemFont(ofSize: 9, weight: .bold)
        badgeLabel.layer.cornerRadius = 8
        badgeLabel.clipsToBounds = true
        badgeLabel.textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, bundleLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.alignment = .leading

        let rightStack = UIStackView(arrangedSubviews: [badgeLabel, versionLabel])
        rightStack.axis = .vertical
        rightStack.spacing = 4
        rightStack.alignment = .trailing

        let hStack = UIStackView(arrangedSubviews: [iconView, textStack, rightStack])
        hStack.axis = .horizontal
        hStack.spacing = 12
        hStack.alignment = .center
        hStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            hStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            hStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            hStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with app: AppCatalog.AppEntry) {
        titleLabel.text = app.name
        bundleLabel.text = app.bundleId
        versionLabel.text = app.version.isEmpty ? nil : app.version
        let (text, color): (String?, UIColor) = {
            if app.isTroll { return ("巨魔", .systemTeal) }
            if app.isSystem { return ("系统", .gray) }
            return ("用户", .systemBlue)
        }()
        badgeLabel.text = text
        badgeLabel.textColor = color
        badgeLabel.backgroundColor = color.withAlphaComponent(0.12)
    }

    func setIcon(_ img: UIImage) {
        iconView.image = img
        iconView.backgroundColor = .clear
    }

    func setPlaceholder() {
        iconView.image = UIImage(systemName: "app.fill")?.withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
        iconView.backgroundColor = .secondarySystemBackground
    }
}

/// 带内边距的 UILabel（版本胶囊/类型徽标用）
final class PaddedLabel: UILabel {
    var textInsets: UIEdgeInsets = .zero
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + textInsets.left + textInsets.right,
                      height: s.height + textInsets.top + textInsets.bottom)
    }
}
