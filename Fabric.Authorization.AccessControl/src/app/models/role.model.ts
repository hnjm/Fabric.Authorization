export class Role {
  public id: string;
  public displayName: string;
  public description: string;
  public parentRole: string;
  public childRoles: Array<string>;

  constructor(
    public name: string,
    public grain: string,
    public securableItem: string
  ) {}
}
