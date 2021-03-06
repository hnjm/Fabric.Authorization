CREATE TABLE [dbo].[Clients](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[ClientId] [nvarchar](max) NOT NULL,
	[CreatedBy] [nvarchar](max) NOT NULL,
	[CreatedDateTimeUtc] [datetime] NOT NULL,
	[IsDeleted] [bit] NOT NULL,
	[ModifiedBy] [nvarchar](max) NULL,
	[ModifiedDateTimeUtc] [datetime] NULL,
	[Name] [nvarchar](200) NOT NULL,
	[SecurableItemId] [uniqueidentifier] NOT NULL,
 CONSTRAINT [PK_Clients] PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [HCFabricAuthorizationData1]
) ON [HCFabricAuthorizationData1] TEXTIMAGE_ON [HCFabricAuthorizationData1]
GO

CREATE UNIQUE NONCLUSTERED INDEX [IX_Clients_SecurableItemId] ON [dbo].[Clients]
(
	[SecurableItemId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [HCFabricAuthorizationIndex1]
GO

ALTER TABLE [dbo].[Clients] ADD  DEFAULT ((0)) FOR [IsDeleted]
GO

ALTER TABLE [dbo].[Clients]  WITH CHECK ADD  CONSTRAINT [FK_Clients_SecurableItems_SecurableItemId] FOREIGN KEY([SecurableItemId])
REFERENCES [dbo].[SecurableItems] ([SecurableItemId])
ON DELETE CASCADE
GO

ALTER TABLE [dbo].[Clients] CHECK CONSTRAINT [FK_Clients_SecurableItems_SecurableItemId]
GO
