{***************************************************************************}
{                                                                           }
{           Spring Framework for Delphi                                     }
{                                                                           }
{           Copyright (c) 2009-2018 Spring4D Team                           }
{                                                                           }
{           http://www.spring4d.org                                         }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

{$I Spring.inc}

unit Spring.Persistence.SQL.Commands.Insert;

interface

uses
  Spring,
  Spring.Collections,
  Spring.Persistence.Core.Interfaces,
  Spring.Persistence.Mapping.Attributes,
  Spring.Persistence.SQL.Commands,
  Spring.Persistence.SQL.Commands.Abstract,
  Spring.Persistence.SQL.Types;

type
  /// <summary>
  ///   Responsible for building and executing <c>insert</c> statements.
  /// </summary>
  TInsertExecutor = class(TAbstractCommandExecutor, IInsertCommand)
  private
    fTable: TSQLTable;
    fColumns: IList<ColumnAttribute>;
    fLastInsertIdSQL: string;
    fGetSequenceValueSQL: string;
    fClientAutoGeneratedValue: Variant;
  protected
    fCommand: TInsertCommand;
    function SupportsIdentityColumn: Boolean; virtual;
    function SupportsSequences: Boolean; virtual;
    function CanClientAutogenerateValue: Boolean; virtual;
    function GetCommand: TDMLCommand; override;

    function GetAutogeneratedPrimaryKeyValue: TValue;
    function GetInsertQueryText: string;
    function GetIdentityValue(const resultSet: IDBResultSet): TValue;
    procedure SetPrimaryKey(const entity: TObject; const value: TValue);

    function ResolveGetSequenceSQL: string;

    property InsertCommand: TInsertCommand read fCommand;
    property Table: TSQLTable read FTable;
  public
    constructor Create(const connection: IDBConnection); override;
    destructor Destroy; override;

    procedure Build(entityClass: TClass); override;
    procedure BuildParams(const entity: TObject); override;
    procedure Execute(const entity: TObject); virtual;
  end;

implementation

uses
  Variants,
  Spring.Persistence.Core.Exceptions,
  Spring.Persistence.SQL.Params,
  Spring.Reflection;


{$REGION 'TInsertCommand'}

constructor TInsertExecutor.Create(const connection: IDBConnection);
begin
  inherited Create(connection);
  fColumns := TCollections.CreateList<ColumnAttribute>;
  fClientAutoGeneratedValue := Null;
  fTable := TSQLTable.Create;
  fCommand := TInsertCommand.Create(fTable);
end;

destructor TInsertExecutor.Destroy;
begin
  fCommand.Free;
  fTable.Free;
  inherited Destroy;
end;

procedure TInsertExecutor.Build(entityClass: TClass);
begin
  inherited Build(entityClass);

  fTable.SetFromAttribute(EntityData.EntityTable);
  fColumns.AddRange(EntityData.Columns);
   // add fields to tsqltable
  fCommand.Sequence := EntityData.Sequence;
  fCommand.SetCommandFieldsFromColumns(fColumns);

  if EntityData.HasSequence then
  begin
    fGetSequenceValueSQL := ResolveGetSequenceSQL;
    if fGetSequenceValueSQL <> '' then
    begin
      if not fCommand.InsertFields.Any(function(const value: TSQLInsertField): Boolean
        begin
          Result := value.Column = EntityData.PrimaryKeyColumn;
        end)
      then
        fCommand.InsertFields.Add(
          TSQLInsertField.Create(
            EntityData.PrimaryKeyColumn.ColumnName,
            fTable, EntityData.PrimaryKeyColumn,
            fCommand.GetAndIncParameterName(EntityData.PrimaryKeyColumn.ColumnName)));
    end;
  end;

  SQL := Generator.GenerateInsert(fCommand);

  if EntityData.PrimaryKeyColumn.IsIdentity then
  begin
    fLastInsertIdSQL := Generator.GenerateGetLastInsertId(EntityData.PrimaryKeyColumn);
    fClientAutoGeneratedValue := Generator.GenerateUniqueId;
  end;
end;

procedure TInsertExecutor.BuildParams(const entity: TObject);
var
  param: TDBParam;
  insertField: TSQLInsertField;
begin
  inherited BuildParams(entity);
  fCommand.Entity := entity;

  for insertField in fCommand.InsertFields do
  begin
    param := Generator.CreateParam(insertField, insertField.Column.GetValue(entity));
    SQLParameters.Add(param);
  end;
end;

function TInsertExecutor.CanClientAutogenerateValue: Boolean;
begin
  Result := not VarIsNull(fClientAutoGeneratedValue);
end;

procedure TInsertExecutor.SetPrimaryKey(const entity: TObject; const value: TValue);
begin
  if not value.IsEmpty then
    with EntityData.PrimaryKeyColumn.Member do
      SetValue(entity, value.Convert(MemberType.Handle));
end;

function TInsertExecutor.SupportsIdentityColumn: Boolean;
begin
  Result := fLastInsertIdSQL <> '';
end;

function TInsertExecutor.SupportsSequences: Boolean;
begin
  Result := fGetSequenceValueSQL <> '';
end;

procedure TInsertExecutor.Execute(const entity: TObject);
var
  value: TValue;
  sqlStatement: string;
  statement: IDBStatement;
  resultSet: IDBResultSet;
begin
  if EntityData.HasVersionColumn then
    EntityData.VersionColumn.Member.SetValue(entity, EntityData.VersionColumn.InitialValue);

  value := GetAutogeneratedPrimaryKeyValue;
  SetPrimaryKey(entity, value);

  BuildParams(entity);
  sqlStatement := GetInsertQueryText;
  statement := Connection.CreateStatement;
  statement.SetSQLCommand(sqlStatement);
  statement.SetParams(SQLParameters);
  // Certain adapters will fail (Oracle ADO) since the DB will return only
  // scalar value and not a result set so only request it when needed.
  if SupportsIdentityColumn then
  begin
    resultSet := statement.ExecuteQuery(False);
    value := GetIdentityValue(resultSet);
    SetPrimaryKey(entity, value);
  end
  else
    statement.Execute;
end;

function TInsertExecutor.GetInsertQueryText: string;
begin
  Result := SQL;
  if Result = '' then
    Result := Generator.GenerateInsert(fCommand);

  if SupportsIdentityColumn then
    Result := Result + sLineBreak + fLastInsertIdSQL;
end;

function TInsertExecutor.ResolveGetSequenceSQL: string;
begin
  if EntityData.Sequence.SequenceSQL <> '' then
    Result := EntityData.Sequence.SequenceSQL
  else
    Result := Generator.GenerateGetNextSequenceValue(EntityData.Sequence);
end;

function TInsertExecutor.GetIdentityValue(const resultSet: IDBResultSet): TValue;
var
  results: IDBResultSet;
  statement: IDBStatement;
begin
  Result := TValue.Empty;
  if not SupportsIdentityColumn then
    Exit;
  results := resultSet;
  if results.IsEmpty then
  begin
    statement := Connection.CreateStatement;
    statement.SetSQLCommand(fLastInsertIdSQL);
    results := statement.ExecuteQuery(False);
  end;

  if not results.IsEmpty then
    Result := TValue.FromVariant(results.GetFieldValue(0));
end;

function TInsertExecutor.GetAutogeneratedPrimaryKeyValue: TValue;
var
  statement: IDBStatement;
  value: Variant;
begin
  Result := TValue.Empty;
  if SupportsSequences then
  begin
    statement := Connection.CreateStatement;
    statement.SetSQLCommand(fGetSequenceValueSQL);
    value := statement.ExecuteQuery.GetFieldValue(0);
    Result := TValue.FromVariant(value);
  end
  else if CanClientAutogenerateValue then
  begin
    Result := TValue.FromVariant(Generator.GenerateUniqueId);
    fCommand.InsertFields.Add(
      TSQLInsertField.Create(
        EntityData.PrimaryKeyColumn.ColumnName,
        fTable, EntityData.PrimaryKeyColumn,
        fCommand.GetAndIncParameterName(EntityData.PrimaryKeyColumn.ColumnName)));
  end;
end;

function TInsertExecutor.GetCommand: TDMLCommand;
begin
  Result := fCommand;
end;

{$ENDREGION}


end.