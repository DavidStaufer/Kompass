import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 320)
        } detail: {
            DetailRouter(selection: app.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
                .inspector(isPresented: $app.showAssistant) {
                    AssistantPanel()
                        .inspectorColumnWidth(min: 340, ideal: 410, max: 600)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .automatic) {
                        Spacer()
                        FocusToolbarButton()
                        Button {
                            withAnimation(Motion.standard) { app.showAssistant.toggle() }
                        } label: {
                            Label("Assistent", systemImage: "sparkles")
                        }
                        .help("KI-Assistent ein-/ausblenden (⌘J)")
                    }
                }
        }
        .overlay(alignment: .bottom) {
            if let t = app.toast {
                ToastView(toast: t)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $app.sheet) { sheet in
            SheetRouter(sheet: sheet).sheetBackground()
        }
        #if os(iOS)
        .sheet(isPresented: $app.showSettings) { SettingsView() }
        #endif
        .task { await app.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.checkForRemoteChanges() }
            if phase == .background { store.saveNow(force: true) }
        }
        .modifier(CompactLayoutReader())
        .alert("Daten konnten nicht geladen werden", isPresented: Bindable(store).showsLoadError) {
            Button("OK") { store.loadError = nil }
        } message: {
            Text(store.loadError ?? "")
        }
    }
}

struct DetailRouter: View {
    var selection: SidebarItem?
    var body: some View {
        switch selection {
        case .today, .none: TodayView()
        case .calendar: CalendarScreen()
        case .week: WeekReviewView()
        case .deadlines: DeadlinesView()
        case .cards: FlashcardsHome()
        case .time: TimeTrackerView()
        case .module(let id): ModuleDetailView(moduleID: id).id(id)
        }
    }
}

struct SheetRouter: View {
    var sheet: AppSheet
    var body: some View {
        switch sheet {
        case .newModule: ModuleEditor(moduleID: nil)
        case .editModule(let id): ModuleEditor(moduleID: id)
        case .deadline(let id, let m, let k): DeadlineEditor(deadlineID: id, presetModule: m, presetKind: k)
        case .newEvent(let s, let e, let m): EventEditor(eventID: nil, start: s, end: e, moduleID: m)
        case .editEvent(let id): EventEditor(eventID: id, start: Date(), end: Date(), moduleID: nil)
        case .planner(let w): PlannerSheet(weekStart: w)
        case .quiz(let id): QuizRunner(quizID: id)
        case .doc(let id): DocumentSheet(docID: id)
        case .generator(let k, let m, let mats): GeneratorSheet(kind: k, moduleID: m, preselected: mats)
        case .cardReview(let m): CardReviewSheet(moduleID: m)
        case .task(let id, let m): TaskEditor(taskID: id, moduleID: m)
        case .logWork(let p): LogWorkSheet(preset: p)
        case .term(let id): TermEditor(termID: id)
        case .onboarding: OnboardingView()
        case .wueCourses: WueCourseSheet()
        }
    }
}

// MARK: - Seitenleiste

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(FocusTimer.self) private var timer

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section {
                Label("Heute", systemImage: "sun.max").tag(SidebarItem.today)
                Label("Kalender", systemImage: "calendar").tag(SidebarItem.calendar)
                Label("Wochenplan", systemImage: "chart.bar.doc.horizontal")
                    .badge(isReviewDay ? Text("Rückblick").foregroundStyle(Color.accentColor) : nil)
                    .tag(SidebarItem.week)
                // Zähler als eigene Views: Änderungen an Karten oder Kalender aktualisieren nur die eine Zeile.
                DeadlinesSidebarLabel().tag(SidebarItem.deadlines)
                CardsSidebarLabel().tag(SidebarItem.cards)
                TimeSidebarLabel().tag(SidebarItem.time)
            }

            Section {
                ForEach(store.activeModules) { m in
                    ModuleSidebarRow(module: m)
                        .tag(SidebarItem.module(m.id))
                        .contextMenu {
                            Button("Bearbeiten …") { app.sheet = .editModule(m.id) }
                            Button("Frist hinzufügen …") { app.sheet = .deadline(nil, moduleID: m.id, kind: nil) }
                            Button("Assistent zu diesem Modul") { app.assistant.scopeModuleID = m.id; app.showAssistant = true }
                            Divider()
                            Button("Archivieren") { store.updateModule(m.id) { $0.archived = true } }
                        }
                }
                Button {
                    app.sheet = .newModule
                } label: {
                    Label("Modul hinzufügen", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } header: {
                TermHeader()
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Kompass")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.showSettings = true } label: { Label("Einstellungen", systemImage: "gearshape") }
            }
        }
        #endif
        .safeAreaInset(edge: .bottom) {
            if timer.isRunning {
                FocusMiniCard()
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: timer.isRunning)
    }

    private var isReviewDay: Bool {
        let wd = Date().isoWeekday
        return wd == 7 || (wd == 1 && Date().minutesSinceMidnight < 12 * 60)
    }
}

private struct DeadlinesSidebarLabel: View {
    @Environment(DataStore.self) private var store
    var body: some View {
        Label("Fristen", systemImage: "flag").badge(store.urgentDeadlineCount)
    }
}

private struct CardsSidebarLabel: View {
    @Environment(DataStore.self) private var store
    var body: some View {
        Label("Karteikarten", systemImage: "rectangle.on.rectangle.angled").badge(store.dueCards().count)
    }
}

private struct TimeSidebarLabel: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Label("Zeiten", systemImage: "clock").badge(app.pendingConfirmations().count)
    }
}

struct TermHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store

    var body: some View {
        Menu {
            Picker("Semester", selection: Bindable(store).selectedTermID) {
                ForEach(store.terms.sorted { $0.start > $1.start }) { t in Text(t.name).tag(UUID?.some(t.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Neues Semester …") { app.sheet = .term(nil) }
            if let t = store.currentTerm { Button("„\(t.name)“ bearbeiten …") { app.sheet = .term(t.id) } }
        } label: {
            HStack(spacing: 3) {
                Text("Module · \(store.currentTerm?.name ?? "Kein Semester")")
                Image(systemName: "chevron.down").scaledFont(size: 8, weight: .bold).accessibilityHidden(true)
            }
        }
        .plainMenu()
    }
}

struct ModuleSidebarRow: View {
    @Environment(DataStore.self) private var store
    var module: Module

    var body: some View {
        let p = ProgressEngine.progress(for: module, store: store)
        HStack(spacing: 8) {
            ModuleDot(color: module.color.color)
            Text(module.name).lineLimit(1)
            Spacer(minLength: 4)
            if let exam = p.examDate, Date().daysUntil(exam) <= 14 {
                Text("\(max(0, Date().daysUntil(exam))) T")
                    .scaledFont(size: 10, weight: .bold).monospacedDigit()
                    .foregroundStyle(.red)
            }
            ProgressRing(value: p.overall, color: module.color.color, lineWidth: 2.5, size: 15)
        }
    }
}

