import { IGrain } from '../models/grain.model';
import { ISecurableItem } from '../models/securableItem.model';

export const mockSecurableItemApp: ISecurableItem[] = [
  { id: 'app', name: 'appSecurable', clientOwner: 'me', grain: 'app',
  securableItems: [], createdBy: 'me', modifiedBy: 'me'}
];
export const mockRequiredScopesApp: string[] = [];

export const mockSecurableItemDos: ISecurableItem[] = [
  { id: 'dos', name: 'dosSecurable', clientOwner: 'me', grain: 'dos',
  securableItems: [], createdBy: 'me', modifiedBy: 'me'}
];
export const mockRequiredScopesDos: string[] = [];

export const mockGrains: IGrain[] = [
    { id: 'app', name: 'app', securableItems: mockSecurableItemApp, createdBy: 'me',
      modifiedBy: 'me', requiredWriteScopes: mockRequiredScopesApp, isShared: false },
    { id: 'dos', name: 'dos', securableItems: mockSecurableItemDos, createdBy: 'dosAdmin',
      modifiedBy: 'me', requiredWriteScopes: mockRequiredScopesDos, isShared: true }
];

export class FabricAuthGrainServiceMock {
  getAllGrains: jasmine.Spy = jasmine.createSpy('getAllGrains');
  isGrainVisible: jasmine.Spy = jasmine.createSpy('isGrainVisible');
}
