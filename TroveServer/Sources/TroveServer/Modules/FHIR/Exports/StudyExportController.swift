// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import OpenAPIRuntime
import TroveAPIServer


extension Controller {
    func createStudyExport(_ input: Operations.CreateStudyExport.Input) async throws -> Operations.CreateStudyExport.Output {
        guard case .json(let request) = input.body else { throw ServerError.jsonBodyRequired }
        let job = try await studyService.createStudyExport(studyID: input.path.studyId.requireId(), input: request)
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(job)))
    }

    func getStudyExport(_ input: Operations.GetStudyExport.Input) async throws -> Operations.GetStudyExport.Output {
        let job = try await studyService.withStudyExport(
            studyID: input.path.studyId.requireId(), id: input.path.exportId.requireId(), part: "manifest"
        ) {
            try await $0.manifest()
        }
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(job)))
    }

    func executeStudyExport(_ input: Operations.ExecuteStudyExport.Input) async throws -> Operations.ExecuteStudyExport.Output {
        let job = try await studyService.withStudyExport(
            studyID: input.path.studyId.requireId(), id: input.path.exportId.requireId(), part: "manifest", execute: true
        ) {
            try await $0.manifest()
        }
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(job)))
    }

    func getStudyExportPage(_ input: Operations.GetStudyExportPage.Input) async throws -> Operations.GetStudyExportPage.Output {
        let (offset, limit) = (input.query.offset ?? 0, input.query.limit ?? 20)
        let page = try await studyService.withStudyExport(
            studyID: input.path.studyId.requireId(), id: input.path.exportId.requireId(), part: "records:\(offset):\(limit)"
        ) {
            try await $0.page(offset: offset, limit: limit)
        }
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(page)))
    }

    func downloadStudyExport(_ input: Operations.DownloadStudyExport.Input) async throws -> Operations.DownloadStudyExport.Output {
        let bytes = try await studyService.withStudyExport(
            studyID: input.path.studyId.requireId(), id: input.path.exportId.requireId(), part: "download"
        ) {
            try await $0.download()
        }
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .binary(HTTPBody(bytes))))
    }
}
