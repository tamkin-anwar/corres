import SwiftData

/// Versioned from the start even though there is only one version today —
/// the schema will change once Gmail-backed data lands, and retrofitting a
/// migration plan after the fact risks the exact "silent data loss on
/// upgrade" failure Docs/Product.md's local-first milestone exists to avoid.
public enum CorresSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] { [PersistedCorrespondence.self] }
}

public enum CorresMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [CorresSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
