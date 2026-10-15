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
        searchWrap.addSubview(searchBar)

        categoryControl.selectedSegmentIndex = 0
        categoryControl.addTarget(self, action: #selector(categoryChanged(_:)), for: .valueChanged)
        // 加大分段控件字号（原生默认偏小）
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold)
        ]
        categoryControl.setTitleTextAttributes(attrs, for: .normal)
        categoryControl.setTitleTextAttributes(attrs, for: .selected)

        let header = UIView()
        header.addSubview(searchWrap)
        header.addSubview(categoryControl)
        tableView.tableHeaderView = header
        layoutHeader(width: 320) // 初始占位宽度，viewDidLayoutSubviews 里按实际宽度修正
        rebuild()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let header = tableView.tableHeaderView, header.frame.width != tableView.bounds.width {
            layoutHeader(width: tableView.bounds.width)
        }
    }

    private func layoutHeader(width: CGFloat) {
        guard let header = tableView.tableHeaderView else { return }
        let sbH: CGFloat = 50, catH: CGFloat = 40, gap: CGFloat = 6
        searchWrap.frame = CGRect(x: 16, y: 4, width: width - 32, height: sbH)
        searchBar.frame = searchWrap.bounds.insetBy(dx: 6, dy: 0)
        categoryControl.frame = CGRect(x: 16, y: 4 + sbH + gap, width: width - 32, height: catH)
        header.frame = CGRect(x: 0, y: 0, width: width, height: 4 + sbH + gap + catH + 6)
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
