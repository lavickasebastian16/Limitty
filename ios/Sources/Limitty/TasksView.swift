#if os(iOS)
import SwiftUI
import LimittyCore

/// "Tasks": give work to the CEO on your PC and follow it.
struct TasksSection: View {
    @Environment(AppModel.self) private var model
    @Binding var showNewTask: Bool
    @Binding var showGitHub: Bool

    var body: some View {
        Section {
            if !model.canSendTasks {
                Text(model.github == nil
                     ? "Sign in with GitHub (below) and connect your PC to give tasks to your agents."
                     : "Link your PC: in the Limitty desktop app press Install agents, or Settings → iPhone → Link iPhone….")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Button {
                    showNewTask = true
                } label: {
                    Label("New task", systemImage: "plus.circle.fill")
                }
                .disabled(model.company?.projects.isEmpty ?? true)
                if model.company?.projects.isEmpty ?? true {
                    Text("Add a project folder on your PC first (the prompt box or the Company window).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.pendingTasks, id: \.id) { req in
                    HStack {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text(req.title ?? "").lineLimit(2)
                            Text("Sent · waiting for your PC to pick it up").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach((model.company?.tasks ?? []).prefix(15)) { task in
                    NavigationLink { TaskDetailView(taskID: task.id) } label: { TaskRow(task: task) }
                }
            }
        } header: {
            Text("Tasks")
        } footer: {
            if model.canSendTasks {
                Text("The CEO on your PC plans each task and hands it to Claude Code, Codex or Antigravity. They work directly in the project folder.")
            }
        }
    }
}

struct TaskRow: View {
    let task: CompanyTask

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title).lineLimit(2)
                Spacer(minLength: 6)
                StatusPill(task: task)
            }
            HStack(spacing: 6) {
                Text(task.project)
                if let steps = task.plan?.steps, !steps.isEmpty {
                    Text("·")
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                        Image(systemName: stepSymbol(s.status)).foregroundStyle(workerColor(s.worker))
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct StatusPill: View {
    let task: CompanyTask

    var body: some View {
        Text(task.statusLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    var color: Color {
        switch task.status {
        case "done", "running": AgentState.working.color
        case "failed": AgentState.attention.color
        case "cancelled": .secondary
        default: Provider.gemini.color
        }
    }
}

func workerColor(_ id: String) -> Color {
    switch id {
    case "claude": Provider.claude.color
    case "codex": Provider.codex.color
    case "agy": Provider.gemini.color
    default: .secondary
    }
}

func stepSymbol(_ status: String) -> String {
    switch status {
    case "done": "checkmark.circle.fill"
    case "running": "bolt.circle.fill"
    case "failed": "xmark.circle.fill"
    case "cancelled", "skipped": "minus.circle"
    default: "circle"
    }
}

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let taskID: String
    @State private var working = false

    var task: CompanyTask? { model.company?.tasks.first { $0.id == taskID } }

    var body: some View {
        List {
            if let task {
                Section {
                    Text(task.title)
                    LabeledContent("Project", value: task.project)
                    LabeledContent("Status") { StatusPill(task: task) }
                    if let error = task.error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                if let plan = task.plan {
                    Section("CEO's plan (\(workerName(plan.by ?? "")))") {
                        Text(plan.summary).font(.footnote)
                    }
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, step in
                        Section {
                            HStack {
                                Image(systemName: stepSymbol(step.status)).foregroundStyle(workerColor(step.worker))
                                Text(workerName(step.worker)).fontWeight(.semibold)
                                if let label = step.modelLabel, step.model != "default" {
                                    Text(label).foregroundStyle(.secondary)
                                }
                                if plan.by == step.worker {
                                    Text("CEO")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 4)
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Provider.claude.color))
                                        .foregroundStyle(Provider.claude.color)
                                }
                                Spacer()
                                Text(step.status).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(step.title).font(.footnote)
                            if let why = step.why, !why.isEmpty {
                                Text("Why \(workerName(step.worker)): \(why)").font(.caption).italic().foregroundStyle(.secondary)
                            }
                            if let out = step.output, !out.isEmpty {
                                Text(out)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        } header: {
                            Text("Step \(i + 1)")
                        }
                    }
                }
                Section {
                    if task.isActive {
                        Button("Cancel task", role: .destructive) { act("cancel", task) }
                    } else {
                        Button("Run again") { act("retry", task) }
                        Button("Remove", role: .destructive) { act("remove", task) }
                    }
                } footer: {
                    Text("Your PC picks this up within about 15 seconds.")
                }
                .disabled(working)
            } else {
                Text("This task is no longer listed.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func act(_ kind: String, _ task: CompanyTask) {
        working = true
        Task {
            await model.taskAction(kind, task)
            working = false
        }
    }
}

struct NewTaskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var project = ""
    @State private var worker = "auto"
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What should the team do?") {
                    TextField("e.g. Add a dark mode toggle to settings and test it", text: $title, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    Picker("Project", selection: $project) {
                        ForEach(model.company?.projects ?? [], id: \.name) { Text($0.name).tag($0.name) }
                    }
                    Picker("Worker", selection: $worker) {
                        Text("CEO decides").tag("auto")
                        ForEach(CompanyState.workerOrder, id: \.self) { id in
                            let w = model.company?.workers[id]
                            Text(label(id, w)).tag(id)
                        }
                    }
                } footer: {
                    Text("The CEO picks the worker and model for each step: a stronger model for hard work, a lighter one for simple work, and whoever has the most usage limit left. It can also do steps itself.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else {
                        Button("Send") { send() }
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.isEmpty)
                    }
                }
            }
            .onAppear { if project.isEmpty { project = model.company?.projects.first?.name ?? "" } }
        }
    }

    private func label(_ id: String, _ w: CompanyState.Worker?) -> String {
        guard let w else { return workerName(id) }
        if !w.available { return "\(workerName(id)) (not available)" }
        if let left = w.remaining { return "\(workerName(id)) · \(Int(left.rounded()))% left" }
        return workerName(id)
    }

    private func send() {
        sending = true
        error = nil
        Task {
            do {
                try await model.sendTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines), project: project, worker: worker)
                dismiss()
            } catch let e as LimitError {
                error = e.message
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
#endif
