//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveVapor
import OpenAPIRuntime
import OpenAPIVapor
import TroveAPIServer
import Vapor


struct Controller: APIProtocol {
    private var grove: GroveVapor

    init(grove: GroveVapor) {
        self.grove = grove
    }
}


// MARK: - Services

extension Controller {
    var studyService: StudyService {
        grove[StudyService.self]
    }

    var componentService: ComponentService {
        grove[ComponentService.self]
    }

    var componentScheduleService: ComponentScheduleService {
        grove[ComponentScheduleService.self]
    }

    var groupService: GroupService {
        grove[GroupService.self]
    }

    var studyBundleService: StudyBundleService {
        grove[StudyBundleService.self]
    }

    var profileService: ProfileService {
        grove[ProfileService.self]
    }

    var invitationCodeService: InvitationCodeService {
        grove[InvitationCodeService.self]
    }

    var publishedStudyService: PublishedStudyService {
        grove[PublishedStudyService.self]
    }

    var enrollmentService: EnrollmentService {
        grove[EnrollmentService.self]
    }

    var participantEnrollmentService: ParticipantEnrollmentService {
        grove[ParticipantEnrollmentService.self]
    }

    var consentService: ConsentService {
        grove[ConsentService.self]
    }

    var fhirResourceService: FHIRResourceService {
        grove[FHIRResourceService.self]
    }

    var objectStorageService: ObjectStorageService {
        grove[ObjectStorageService.self]
    }

    var authorizationService: AuthorizationService {
        grove[AuthorizationService.self]
    }
}
