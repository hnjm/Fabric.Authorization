import { TestBed, inject } from '@angular/core/testing';

import { ClientAccessControlConfigService } from './client-access-control-config.service';
import { AuthService } from './auth.service';
import { ServicesService } from '../global/services.service';
import { ConfigService } from '../global/config.service';
import { HttpClientTestingModule } from '@angular/common/http/testing';
import { MockAuthService } from './auth.service.mock';

describe('ClientAccessControlConfigService', () => {
  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        ClientAccessControlConfigService,
        ServicesService,
        ConfigService,
        {
          provide: 'IAuthService',
          useClass: MockAuthService
        }
      ],
      imports: [HttpClientTestingModule]
    });
  });

  it(
    'should be created',
    inject(
      [ClientAccessControlConfigService],
      (service: ClientAccessControlConfigService) => {
        expect(service).toBeTruthy();
      }
    )
  );
});
